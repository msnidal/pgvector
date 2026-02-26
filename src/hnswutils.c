#include "postgres.h"

#include <math.h>

#include "access/genam.h"
#include "access/generic_xlog.h"
#include "access/itup.h"
#include "access/relscan.h"
#include "catalog/pg_type.h"
#include "catalog/pg_type_d.h"
#include "common/hashfn.h"
#include "fmgr.h"
#include "hnsw.h"
#include "lib/pairingheap.h"
#include "nodes/pg_list.h"
#include "port/atomics.h"
#include "utils/builtins.h"
#include "utils/float.h"
#include "utils/lsyscache.h"
#include "sparsevec.h"
#include "storage/bufmgr.h"
#include "utils/datum.h"
#include "utils/memdebug.h"
#include "utils/rel.h"
#include "utils/typcache.h"
#include "vector.h"

#if PG_VERSION_NUM >= 160000
#include "varatt.h"
#endif

#if PG_VERSION_NUM < 170000
static inline uint64
murmurhash64(uint64 data)
{
	uint64		h = data;

	h ^= h >> 33;
	h *= 0xff51afd7ed558ccd;
	h ^= h >> 33;
	h *= 0xc4ceb9fe1a85ec53;
	h ^= h >> 33;

	return h;
}
#endif

/* TID hash table */
static uint32
hash_tid(ItemPointerData tid)
{
	union
	{
		uint64		i;
		ItemPointerData tid;
	}			x;

	/* Initialize unused bytes */
	x.i = 0;
	x.tid = tid;

	return murmurhash64(x.i);
}

#define SH_PREFIX		tidhash
#define SH_ELEMENT_TYPE	TidHashEntry
#define SH_KEY_TYPE		ItemPointerData
#define	SH_KEY			tid
#define SH_HASH_KEY(tb, key)	hash_tid(key)
#define SH_EQUAL(tb, a, b)		ItemPointerEquals(&a, &b)
#define	SH_SCOPE		extern
#define SH_DEFINE
#include "lib/simplehash.h"

/* Pointer hash table */
static uint32
hash_pointer(uintptr_t ptr)
{
#if SIZEOF_VOID_P == 8
	return murmurhash64((uint64) ptr);
#else
	return murmurhash32((uint32) ptr);
#endif
}

#define SH_PREFIX		pointerhash
#define SH_ELEMENT_TYPE	PointerHashEntry
#define SH_KEY_TYPE		uintptr_t
#define	SH_KEY			ptr
#define SH_HASH_KEY(tb, key)	hash_pointer(key)
#define SH_EQUAL(tb, a, b)		(a == b)
#define	SH_SCOPE		extern
#define SH_DEFINE
#include "lib/simplehash.h"

/* Offset hash table */
static uint32
hash_offset(Size offset)
{
#if SIZEOF_SIZE_T == 8
	return murmurhash64((uint64) offset);
#else
	return murmurhash32((uint32) offset);
#endif
}

#define SH_PREFIX		offsethash
#define SH_ELEMENT_TYPE	OffsetHashEntry
#define SH_KEY_TYPE		Size
#define	SH_KEY			offset
#define SH_HASH_KEY(tb, key)	hash_offset(key)
#define SH_EQUAL(tb, a, b)		(a == b)
#define	SH_SCOPE		extern
#define SH_DEFINE
#include "lib/simplehash.h"

static uint32
HnswDatumHash(Datum value, bool isnull, bool attbyval, int attlen)
{
	uint32 hash = 0;
	if (isnull)
		return 0;

	if (attbyval)
	{
		unsigned char *p = (unsigned char *) &value;
		int len = attlen > 0 ? attlen : sizeof(Datum);
		for (int i = 0; i < len; i++)
			hash = hash * 31 + p[i];
		return murmurhash32(hash);
	}
	else
	{
		unsigned char *s = (unsigned char *) DatumGetPointer(value);
		int			size;

		if (attlen > 0)
			size = attlen;
		else if (attlen == -1)
			size = VARSIZE_ANY(s);
		else
			size = strlen((char *) s) + 1;

		for (int i = 0; i < size; i++)
			hash = hash * 31 + s[i];
		return murmurhash32(hash);
	}
}

typedef struct HnswEpCacheKey
{
	AttrNumber	attno;
	uint32		hash_value;
} HnswEpCacheKey;

typedef struct HnswEpCacheEntry
{
	HnswEpCacheKey key;
	char		status;
	HnswElement element;
} HnswEpCacheEntry;

static inline uint32
hash_ep_key(HnswEpCacheKey key)
{
	return murmurhash32(key.hash_value ^ key.attno);
}

static inline bool
ep_key_equal(HnswEpCacheKey a, HnswEpCacheKey b)
{
	return a.attno == b.attno && a.hash_value == b.hash_value;
}

#define SH_PREFIX		epcache
#define SH_ELEMENT_TYPE	HnswEpCacheEntry
#define SH_KEY_TYPE		HnswEpCacheKey
#define SH_KEY			key
#define SH_HASH_KEY(tb, key)	hash_ep_key(key)
#define SH_EQUAL(tb, a, b)		ep_key_equal(a, b)
#define SH_SCOPE		extern
#define SH_DEFINE
#define SH_DECLARE
#include "lib/simplehash.h"

struct epcache_hash *
HnswInitEpCache(MemoryContext ctx)
{
	return epcache_create(ctx, 128, NULL);
}

void
HnswFreeEpCache(struct epcache_hash *cache)
{
	if (cache)
		epcache_destroy(cache);
}

HnswElement
HnswGetCachedEntryPoint(struct epcache_hash *cache, AttrNumber attno, Datum value, bool isnull, TupleDesc tupdesc)
{
	HnswEpCacheKey key;
	HnswEpCacheEntry *entry;
	Form_pg_attribute attr;

	if (cache == NULL || attno == InvalidAttrNumber)
		return NULL;

	attr = TupleDescAttr(tupdesc, attno - 1);
	key.attno = attno;
	key.hash_value = HnswDatumHash(value, isnull, attr->attbyval, attr->attlen);

	entry = epcache_lookup(cache, key);
	if (entry)
		return entry->element;

	return NULL;
}

void
HnswSetCachedEntryPoint(struct epcache_hash *cache, AttrNumber attno, Datum value, bool isnull, TupleDesc tupdesc, HnswElement element)
{
	HnswEpCacheKey key;
	HnswEpCacheEntry *entry;
	Form_pg_attribute attr;
	bool		found;

	if (cache == NULL || attno == InvalidAttrNumber || element == NULL)
		return;

	attr = TupleDescAttr(tupdesc, attno - 1);
	key.attno = attno;
	key.hash_value = HnswDatumHash(value, isnull, attr->attbyval, attr->attlen);

	entry = epcache_insert(cache, key, &found);
	entry->element = element;
}

/*
 * Get the max number of connections in an upper layer for each element in the index
 */
int
HnswGetM(Relation index)
{
	HnswOptions *opts = (HnswOptions *) index->rd_options;

	if (opts)
		return opts->m;

	return HNSW_DEFAULT_M;
}

/*
 * Get the size of the dynamic candidate list in the index
 */
int
HnswGetEfConstruction(Relation index)
{
	HnswOptions *opts = (HnswOptions *) index->rd_options;

	if (opts)
		return opts->efConstruction;

	return HNSW_DEFAULT_EF_CONSTRUCTION;
}

/*
 * Get total auxiliary connections
 */
int
HnswGetAuxM(Relation index)
{
	HnswOptions *opts = (HnswOptions *) index->rd_options;

	if (opts)
		return opts->auxM >= 0 ? opts->auxM : opts->m;

	return HNSW_DEFAULT_M;
}

/*
 * Get proc
 */
FmgrInfo *
HnswOptionalProcInfo(Relation index, uint16 procnum)
{
	if (!OidIsValid(index_getprocid(index, 1, procnum)))
		return NULL;

	return index_getprocinfo(index, 1, procnum);
}

/*
 * Init support functions
 */
void
HnswInitSupport(HnswSupport * support, Relation index)
{
	support->procinfo = index_getprocinfo(index, 1, HNSW_DISTANCE_PROC);
	support->collation = index->rd_indcollation[0];
	support->normprocinfo = HnswOptionalProcInfo(index, HNSW_NORM_PROC);
}

/*
 * Normalize value
 */
Datum
HnswNormValue(const HnswTypeInfo * typeInfo, Oid collation, Datum value)
{
	return DirectFunctionCall1Coll(typeInfo->normalize, collation, value);
}

/*
 * Check if non-zero norm
 */
bool
HnswCheckNorm(HnswSupport * support, Datum value)
{
	return DatumGetFloat8(FunctionCall1Coll(support->normprocinfo, support->collation, value)) > 0;
}

/*
 * New buffer
 */
Buffer
HnswNewBuffer(Relation index, ForkNumber forkNum)
{
	Buffer		buf = ReadBufferExtended(index, forkNum, P_NEW, RBM_NORMAL, NULL);

	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	return buf;
}

/*
 * Init page
 */
void
HnswInitPage(Buffer buf, Page page)
{
	PageInit(page, BufferGetPageSize(buf), sizeof(HnswPageOpaqueData));
	HnswPageGetOpaque(page)->nextblkno = InvalidBlockNumber;
	HnswPageGetOpaque(page)->page_id = HNSW_PAGE_ID;
}

/*
 * Allocate a neighbor array
 */
HnswNeighborArray *
HnswInitNeighborArray(int lm, HnswAllocator * allocator)
{
	HnswNeighborArray *a = HnswAlloc(allocator, HNSW_NEIGHBOR_ARRAY_SIZE(lm));

	a->length = 0;
	a->closerSet = false;
	return a;
}

/*
 * Allocate neighbors
 */
void
HnswInitNeighbors(char *base, HnswElement element, int m, HnswAllocator * allocator)
{
	int			level = element->level;
	HnswNeighborArrayPtr *neighborList = (HnswNeighborArrayPtr *) HnswAlloc(allocator, sizeof(HnswNeighborArrayPtr) * (level + 1));

	HnswPtrStore(base, element->neighbors, neighborList);

	for (int lc = 0; lc <= level; lc++)
		HnswPtrStore(base, neighborList[lc], HnswInitNeighborArray(HnswGetLayerM(m, lc), allocator));
}

/*
 * Allocate auxiliary neighbors
 */
static void
HnswInitAuxNeighbors(char *base, HnswElement element, int m, int auxM, int natts, HnswAllocator * allocator)
{
	int			auxAttrs = HnswGetAuxAttributeCount(natts);
	HnswNeighborArrayPtr *auxList;

	if (auxAttrs == 0)
	{
		HnswPtrStore(base, element->auxNeighbors, (HnswNeighborArrayPtr *) NULL);
		return;
	}

	auxList = (HnswNeighborArrayPtr *) HnswAlloc(allocator, sizeof(HnswNeighborArrayPtr) * auxAttrs);
	HnswPtrStore(base, element->auxNeighbors, auxList);

	for (AttrNumber attno = 2; attno <= natts; attno++)
		HnswPtrStore(base, auxList[attno - 2], HnswInitNeighborArray(HnswGetAuxMForAttno(auxM, natts, attno), allocator));
}

/*
 * Allocate memory from the allocator
 */
void *
HnswAlloc(HnswAllocator * allocator, Size size)
{
	if (allocator)
		return (*(allocator)->alloc) (size, (allocator)->state);

	return palloc(size);
}

/*
 * Allocate an element
 */
HnswElement
HnswInitElement(char *base, ItemPointer heaptid, int m, double ml, int maxLevel, int natts, int auxM, HnswAllocator * allocator)
{
	HnswElement element = HnswAlloc(allocator, sizeof(HnswElementData));

	int			level = (int) (-log(RandomDouble()) * ml);

	/* Cap level */
	if (level > maxLevel)
		level = maxLevel;

	element->heaptidsLength = 0;
	HnswAddHeapTid(element, heaptid);

	element->level = level;
	element->deleted = 0;
	/* Start at one to make it easier to find issues */
	element->version = 1;

	HnswInitNeighbors(base, element, m, allocator);
	HnswInitAuxNeighbors(base, element, m, auxM, natts, allocator);

	HnswPtrStore(base, element->value, (Pointer) NULL);
	HnswPtrStore(base, element->itup, (IndexTuple) NULL);

	return element;
}

/*
 * Add a heap TID to an element
 */
void
HnswAddHeapTid(HnswElement element, ItemPointer heaptid)
{
	element->heaptids[element->heaptidsLength++] = *heaptid;
}

/*
 * Allocate an element from block and offset numbers
 */
HnswElement
HnswInitElementFromBlock(BlockNumber blkno, OffsetNumber offno)
{
	HnswElement element = palloc(sizeof(HnswElementData));
	char	   *base = NULL;

	element->blkno = blkno;
	element->offno = offno;
	HnswPtrStore(base, element->neighbors, (HnswNeighborArrayPtr *) NULL);
	HnswPtrStore(base, element->auxNeighbors, (HnswNeighborArrayPtr *) NULL);
	HnswPtrStore(base, element->value, (Pointer) NULL);
	HnswPtrStore(base, element->itup, (IndexTuple) NULL);
	return element;
}

/*
 * Get the metapage info
 */
void
HnswGetMetaPageInfo(Relation index, int *m, HnswElement * entryPoint)
{
	Buffer		buf;
	Page		page;
	HnswMetaPage metap;

	buf = ReadBuffer(index, HNSW_METAPAGE_BLKNO);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	page = BufferGetPage(buf);
	metap = HnswPageGetMeta(page);

	if (unlikely(metap->magicNumber != HNSW_MAGIC_NUMBER))
		elog(ERROR, "hnsw index is not valid");

	if (unlikely(metap->version != HNSW_VERSION))
		elog(ERROR, "hnsw index version not supported");

	if (m != NULL)
		*m = metap->m;

	if (entryPoint != NULL)
	{
		if (BlockNumberIsValid(metap->entryBlkno))
		{
			*entryPoint = HnswInitElementFromBlock(metap->entryBlkno, metap->entryOffno);
			(*entryPoint)->level = metap->entryLevel;
		}
		else
			*entryPoint = NULL;
	}

	UnlockReleaseBuffer(buf);
}

/*
 * Get the entry point
 */
HnswElement
HnswGetEntryPoint(Relation index)
{
	HnswElement entryPoint;

	HnswGetMetaPageInfo(index, NULL, &entryPoint);

	return entryPoint;
}

/*
 * Update the metapage info
 */
static void
HnswUpdateMetaPageInfo(Page page, int updateEntry, HnswElement entryPoint, BlockNumber insertPage)
{
	HnswMetaPage metap = HnswPageGetMeta(page);

	if (updateEntry)
	{
		if (entryPoint == NULL)
		{
			metap->entryBlkno = InvalidBlockNumber;
			metap->entryOffno = InvalidOffsetNumber;
			metap->entryLevel = -1;
		}
		else if (entryPoint->level > metap->entryLevel || updateEntry == HNSW_UPDATE_ENTRY_ALWAYS)
		{
			metap->entryBlkno = entryPoint->blkno;
			metap->entryOffno = entryPoint->offno;
			metap->entryLevel = entryPoint->level;
		}
	}

	if (BlockNumberIsValid(insertPage))
		metap->insertPage = insertPage;
}

/*
 * Update the metapage
 */
void
HnswUpdateMetaPage(Relation index, int updateEntry, HnswElement entryPoint, BlockNumber insertPage, ForkNumber forkNum, bool building)
{
	Buffer		buf;
	Page		page;
	GenericXLogState *state;

	buf = ReadBufferExtended(index, forkNum, HNSW_METAPAGE_BLKNO, RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	if (building)
	{
		state = NULL;
		page = BufferGetPage(buf);
	}
	else
	{
		state = GenericXLogStart(index);
		page = GenericXLogRegisterBuffer(state, buf, 0);
	}

	HnswUpdateMetaPageInfo(page, updateEntry, entryPoint, insertPage);

	if (building)
		MarkBufferDirty(buf);
	else
		GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
}

/*
 * Form index value
 */
bool
HnswFormIndexValue(Datum *out, Datum *values, bool *isnull, const HnswTypeInfo * typeInfo, HnswSupport * support)
{
	/* Detoast once for all calls */
	Datum		value = PointerGetDatum(PG_DETOAST_DATUM(values[0]));

	/* Check value */
	if (typeInfo->checkValue != NULL)
		typeInfo->checkValue(DatumGetPointer(value));

	/* Normalize if needed */
	if (support->normprocinfo != NULL)
	{
		if (!HnswCheckNorm(support, value))
			return false;

		value = HnswNormValue(typeInfo, support->collation, value);
	}

	*out = value;

	return true;
}

/*
 * Get the tuple descriptor
 */
TupleDesc
HnswTupleDesc(Relation index)
{
	TupleDesc	tupdesc = CreateTupleDescCopyConstr(RelationGetDescr(index));

	/* Prevent compression */
	TupleDescAttr(tupdesc, 0)->attstorage = TYPSTORAGE_PLAIN;

	return tupdesc;
}

/*
 * Form an index tuple
 */
IndexTuple
HnswFormIndexTuple(Relation index, TupleDesc tupdesc, Datum value, Datum *values, bool *isnull)
{
	Size		size = sizeof(Datum) * IndexRelationGetNumberOfAttributes(index);
	Datum	   *newValues = palloc(size);

	memcpy(newValues, values, size);
	newValues[0] = value;

	return index_form_tuple(tupdesc, newValues, isnull);
}

/*
 * Set element tuple, except for neighbor info
 */
void
HnswSetElementTuple(char *base, HnswElementTuple etup, HnswElement element)
{
	Pointer		valuePtr = HnswPtrAccess(base, element->value);
	IndexTuple	itup = HnswPtrAccess(base, element->itup);

	etup->type = HNSW_ELEMENT_TUPLE_TYPE;
	etup->level = element->level;
	etup->deleted = element->deleted;
	etup->version = element->version;

	for (int i = 0; i < HNSW_HEAPTIDS; i++)
	{
		if (i < element->heaptidsLength)
			etup->heaptids[i] = element->heaptids[i];
		else
			ItemPointerSetInvalid(&etup->heaptids[i]);
	}

	if (itup != NULL)
		memcpy(&etup->data, itup, IndexTupleSize(itup));
	else
		memcpy(&etup->data, valuePtr, VARSIZE_ANY(valuePtr));
}

/*
 * Set neighbor tuple
 */
void
HnswSetNeighborTuple(char *base, HnswNeighborTuple ntup, HnswElement e, int m, int auxM, int natts)
{
	int			idx = 0;

	ntup->type = HNSW_NEIGHBOR_TUPLE_TYPE;

	for (int lc = e->level; lc >= 0; lc--)
	{
		HnswNeighborArray *neighbors = HnswGetNeighbors(base, e, lc);
		int			lm = HnswGetLayerM(m, lc);

		for (int i = 0; i < lm; i++)
		{
			ItemPointer indextid = &ntup->indextids[idx++];

			if (i < neighbors->length)
			{
				HnswCandidate *hc = &neighbors->items[i];
				HnswElement hce = HnswPtrAccess(base, hc->element);

				ItemPointerSet(indextid, hce->blkno, hce->offno);
			}
			else
				ItemPointerSetInvalid(indextid);
		}
	}

	for (AttrNumber attno = 2; attno <= natts; attno++)
	{
		int			am = HnswGetAuxMForAttno(auxM, natts, attno);
		HnswNeighborArray *auxNeighbors = HnswGetAuxNeighbors(base, e, attno);

		for (int i = 0; i < am; i++)
		{
			ItemPointer indextid = &ntup->indextids[idx++];

			if (auxNeighbors != NULL && i < auxNeighbors->length)
			{
				HnswCandidate *hc = &auxNeighbors->items[i];
				HnswElement hce = HnswPtrAccess(base, hc->element);

				ItemPointerSet(indextid, hce->blkno, hce->offno);
			}
			else
				ItemPointerSetInvalid(indextid);
		}
	}

	ntup->count = idx;
	ntup->version = e->version;
}

/*
 * Load an element from a tuple
 */
void
HnswLoadElementFromTuple(HnswElement element, HnswElementTuple etup, bool loadHeaptids, bool loadVec, Relation index)
{
	element->level = etup->level;
	element->deleted = etup->deleted;
	element->version = etup->version;
	element->neighborPage = ItemPointerGetBlockNumber(&etup->neighbortid);
	element->neighborOffno = ItemPointerGetOffsetNumber(&etup->neighbortid);
	element->heaptidsLength = 0;

	if (loadHeaptids)
	{
		for (int i = 0; i < HNSW_HEAPTIDS; i++)
		{
			/* Can stop at first invalid */
			if (!ItemPointerIsValid(&etup->heaptids[i]))
				break;

			HnswAddHeapTid(element, &etup->heaptids[i]);
		}
	}

	if (loadVec)
	{
		char	   *base = NULL;

		if (IndexRelationGetNumberOfAttributes(index) > 1)
		{
			TupleDesc	tupdesc = RelationGetDescr(index);
			bool		isnull;
			IndexTuple	itup = CopyIndexTuple((IndexTuple) &etup->data);
			Datum		value = index_getattr(itup, 1, tupdesc, &isnull);

			HnswPtrStore(base, element->itup, itup);
			HnswPtrStore(base, element->value, DatumGetPointer(value));
		}
		else
		{
			Datum		value = datumCopy(PointerGetDatum(&etup->data), false, -1);

			HnswPtrStore(base, element->value, (char *) DatumGetPointer(value));
		}
	}

	{
		char	   *base = NULL;

		if (!loadVec)
		{
			HnswPtrStore(base, element->auxNeighbors, (HnswNeighborArrayPtr *) NULL);
			HnswPtrStore(base, element->itup, (IndexTuple) NULL);
			HnswPtrStore(base, element->value, (Pointer) NULL);
		}
	}
}

static bool
HnswElementMatchesInsertFilter(char *base, HnswElement element, Relation index, HnswQuery *q)
{
	IndexTuple	itup = HnswPtrAccess(base, element->itup);
	bool		isnull;
	Datum		value;
	TupleDesc	tupdesc;
	Form_pg_attribute attr;

	if (itup == NULL || index == NULL || q == NULL || q->filterAttno == InvalidAttrNumber)
		return false;

	tupdesc = RelationGetDescr(index);
	attr = TupleDescAttr(tupdesc, q->filterAttno - 1);
	value = index_getattr(itup, q->filterAttno, tupdesc, &isnull);

	if (isnull || q->filterIsnull)
		return isnull == q->filterIsnull;

	return datum_image_eq(value, q->filterValue, attr->attbyval, attr->attlen);
}

static bool
HnswCheckMatches(Relation index, HnswElementTuple etup, IndexScanDesc scan)
{
	if (scan == NULL)
		return true;

	if (IndexRelationGetNumberOfAttributes(index) == 1)
		return true;

	for (int i = 0; i < scan->numberOfKeys; i++)
	{
		IndexTuple	itup = (IndexTuple) &etup->data;
		TupleDesc	tupdesc = RelationGetDescr(index);
		ScanKey		key = &scan->keyData[i];
		bool		isnull;
		Datum		value = index_getattr(itup, key->sk_attno, tupdesc, &isnull);
		bool		attnull = key->sk_flags & SK_ISNULL;

		if (isnull || attnull)
		{
			if (isnull != attnull)
				return false;
		}
		else if (!DatumGetBool(FunctionCall2Coll(&key->sk_func, key->sk_collation, value, key->sk_argument)))
			return false;
	}

	return true;
}

/*
 * Select an auxiliary edge attribute from scan keys
 */
static AttrNumber
HnswGetAuxScanAttno(IndexScanDesc scan, int natts)
{
	AttrNumber	attno = InvalidAttrNumber;

	if (scan == NULL || scan->numberOfKeys == 0)
		return InvalidAttrNumber;

	for (int i = 0; i < scan->numberOfKeys; i++)
	{
		ScanKey		key = &scan->keyData[i];

		if (key->sk_attno <= 1 || key->sk_attno > natts)
			continue;

		if (key->sk_strategy != HNSW_EQUAL_STRATEGY)
			continue;

		if (attno == InvalidAttrNumber || key->sk_attno < attno)
			attno = key->sk_attno;
	}

	return attno;
}

/*
 * Calculate the distance between values
 */
static inline double
HnswGetDistance(Datum a, Datum b, HnswSupport * support)
{
	return DatumGetFloat8(FunctionCall2Coll(support->procinfo, support->collation, a, b));
}

/*
 * Load an element and optionally get its distance from q
 */
static void
HnswLoadElementImpl(BlockNumber blkno, OffsetNumber offno, double *distance, HnswQuery * q, Relation index, HnswSupport * support, bool loadVec, double *maxDistance, HnswElement * element, IndexScanDesc scan, bool *matches)
{
	Buffer		buf;
	Page		page;
	ItemId		itemid;
	HnswElementTuple etup;
	bool		tupleMatches = true;

	/* Read vector */
	buf = ReadBuffer(index, blkno);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	page = BufferGetPage(buf);
	itemid = PageGetItemId(page, offno);
	etup = (HnswElementTuple) PageGetItem(page, itemid);

	Assert(HnswIsElementTuple(etup));

	if (scan != NULL)
		tupleMatches = HnswCheckMatches(index, etup, scan);

	if (matches != NULL)
		*matches = tupleMatches;

	/* Calculate distance */
	if (distance != NULL)
	{
		Datum		value;

		if (DatumGetPointer(q->value) == NULL)
			*distance = 0;
		else if (IndexRelationGetNumberOfAttributes(index) > 1)
		{
			TupleDesc	tupdesc = RelationGetDescr(index);
			bool		isnull;

			value = index_getattr((IndexTuple) &etup->data, 1, tupdesc, &isnull);
			*distance = HnswGetDistance(q->value, value, support);
		}
		else
			*distance = HnswGetDistance(q->value, PointerGetDatum(&etup->data), support);
	}

	/* Load element */
	if (distance == NULL || maxDistance == NULL || *distance < *maxDistance)
	{
		if (*element == NULL)
			*element = HnswInitElementFromBlock(blkno, offno);

		HnswLoadElementFromTuple(*element, etup, true, loadVec, index);
	}

	UnlockReleaseBuffer(buf);
}

/*
 * Load an element and optionally get its distance from q
 */
void
HnswLoadElement(HnswElement element, double *distance, HnswQuery * q, Relation index, HnswSupport * support, bool loadVec, double *maxDistance)
{
	HnswLoadElementImpl(element->blkno, element->offno, distance, q, index, support, loadVec, maxDistance, &element, NULL, NULL);
}

bool
HnswElementMatchesScan(HnswElement element, Relation index, IndexScanDesc scan)
{
	Buffer		buf;
	Page		page;
	ItemId		itemid;
	HnswElementTuple etup;
	bool		matches;

	buf = ReadBuffer(index, element->blkno);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	page = BufferGetPage(buf);
	itemid = PageGetItemId(page, element->offno);
	etup = (HnswElementTuple) PageGetItem(page, itemid);

	matches = HnswCheckMatches(index, etup, scan);

	UnlockReleaseBuffer(buf);

	return matches;
}


/*
 * Build auxiliary Path A edges by performing an attribute-constrained search
 */
void
HnswFindElementAuxNeighbors(char *base, HnswElement element, HnswElement entryPoint, struct epcache_hash *ep_cache, Relation index, HnswSupport * support, int m, int auxM, int efConstruction, bool existing, bool inMemory)
{
	int			natts;
	Datum		value;
	IndexTuple	itupA;
	HnswElement skipElement = existing ? element : NULL;

	if (index == NULL)
		return;

	natts = IndexRelationGetNumberOfAttributes(index);
	if (natts == 1)
		return;

	itupA = HnswPtrAccess(base, element->itup);
	if (itupA == NULL)
		return;

	value = HnswGetValue(base, element);

	for (AttrNumber attno = 2; attno <= natts; attno++)
	{
		int			am = HnswGetAuxMForAttno(auxM, natts, attno);
		HnswNeighborArray *auxNeighbors;
		HnswQuery	q;
		TupleDesc	tupdesc;
		bool		isnull;
		List	   *ep;
		List	   *w;
		ListCell   *lc2;
		HnswElement epElement = entryPoint;
		bool		foundInCache = false;

		if (am == 0)
			continue;

		auxNeighbors = HnswGetAuxNeighbors(base, element, attno);

		tupdesc = RelationGetDescr(index);
		q.value = value;
		q.scan = NULL;
		q.filterAttno = attno;
		q.filterValue = index_getattr(itupA, attno, tupdesc, &isnull);
		q.filterIsnull = isnull;

		/* No neighbors if no entry point */
		if (entryPoint == NULL)
			continue;

		if (ep_cache != NULL)
		{
			HnswElement cachedEp = HnswGetCachedEntryPoint(ep_cache, attno, q.filterValue, isnull, tupdesc);
			if (cachedEp != NULL)
			{
				epElement = cachedEp;
				foundInCache = true;
			}
		}

		ep = list_make1(HnswEntryCandidate(base, epElement, &q, index, support, true, inMemory));

		/* 
		 * If we found a cached entry point, it already matches the attribute.
		 * Since auxiliary edges only exist at layer 0, navigating upper layers
		 * is counterproductive. Skip directly to layer 0.
		 */
		if (!foundInCache)
		{
			/* 1st phase: greedy search to layer 1 */
			for (int lc = epElement->level; lc >= 1; lc--)
			{
				w = HnswSearchLayer(base, &q, ep, 1, lc, index, support, m, true, skipElement, NULL, NULL, true, NULL, inMemory);
				ep = w;
			}
		}

		/* 2nd phase: search layer 0 */
		w = HnswSearchLayer(base, &q, ep, efConstruction, 0, index, support, m, true, skipElement, NULL, NULL, true, NULL, inMemory);


		/* Convert search candidates and add to aux neighbors */
		foreach(lc2, w)
		{
			HnswSearchCandidate *sc = lfirst(lc2);
			HnswElement neighborElement = HnswPtrAccess(base, sc->element);

			if (neighborElement == element)
				continue;

			/* HnswSearchLayer handles the filtering, so we know it matches */
			HnswUpdateConnection(base, auxNeighbors, neighborElement, sc->distance, am, NULL, index, support);

			/* Add backward edge */
			if (base != NULL)
			{
				LWLockAcquire(&neighborElement->lock, LW_EXCLUSIVE);
				HnswUpdateConnection(base, HnswGetAuxNeighbors(base, neighborElement, attno), element, sc->distance, am, NULL, index, support);
				LWLockRelease(&neighborElement->lock);
			}
		}

		/* Cache this element as a future entry point for this attribute value */
		if (ep_cache != NULL)
			HnswSetCachedEntryPoint(ep_cache, attno, q.filterValue, isnull, tupdesc, element);
	}
}

/*
 * Get the distance for an element
 */
static double
GetElementDistance(char *base, HnswElement element, HnswQuery * q, HnswSupport * support)
{
	Datum		value = HnswGetValue(base, element);

	return HnswGetDistance(q->value, value, support);
}

/*
 * Allocate a search candidate
 */
static HnswSearchCandidate *
HnswInitSearchCandidate(char *base, HnswElement element, double distance, bool matches_scan)
{
	HnswSearchCandidate *sc = palloc(sizeof(HnswSearchCandidate));

	HnswPtrStore(base, sc->element, element);
	sc->distance = distance;
	sc->matches_scan = matches_scan;
	return sc;
}

/*
 * Create a candidate for the entry point
 */
HnswSearchCandidate *
HnswEntryCandidate(char *base, HnswElement entryPoint, HnswQuery * q, Relation index, HnswSupport * support, bool loadVec, bool inMemory)
{
	
	double		distance;
	bool		matches_scan = true;
	bool		checkFilter = !inMemory && q != NULL && q->scan != NULL && q->scan->numberOfKeys > 0;

	if (inMemory)
		distance = GetElementDistance(base, entryPoint, q, support);
	else
		HnswLoadElementImpl(entryPoint->blkno, entryPoint->offno, &distance, q, index, support, loadVec, NULL, &entryPoint, checkFilter ? q->scan : NULL, checkFilter ? &matches_scan : NULL);

	return HnswInitSearchCandidate(base, entryPoint, distance, matches_scan);
}

/*
 * Compare candidate distances
 */
static int
CompareNearestCandidates(const pairingheap_node *a, const pairingheap_node *b, void *arg)
{
	if (HnswGetSearchCandidateConst(c_node, a)->distance < HnswGetSearchCandidateConst(c_node, b)->distance)
		return 1;

	if (HnswGetSearchCandidateConst(c_node, a)->distance > HnswGetSearchCandidateConst(c_node, b)->distance)
		return -1;

	return 0;
}

/*
 * Compare discarded candidate distances
 */
static int
CompareNearestDiscardedCandidates(const pairingheap_node *a, const pairingheap_node *b, void *arg)
{
	if (HnswGetSearchCandidateConst(w_node, a)->distance < HnswGetSearchCandidateConst(w_node, b)->distance)
		return 1;

	if (HnswGetSearchCandidateConst(w_node, a)->distance > HnswGetSearchCandidateConst(w_node, b)->distance)
		return -1;

	return 0;
}

/*
 * Compare candidate distances
 */
static int
CompareFurthestCandidates(const pairingheap_node *a, const pairingheap_node *b, void *arg)
{
	if (HnswGetSearchCandidateConst(w_node, a)->distance < HnswGetSearchCandidateConst(w_node, b)->distance)
		return -1;

	if (HnswGetSearchCandidateConst(w_node, a)->distance > HnswGetSearchCandidateConst(w_node, b)->distance)
		return 1;

	return 0;
}

/*
 * Compare matched candidate distances
 */
static int
CompareFurthestMatchedCandidates(const pairingheap_node *a, const pairingheap_node *b, void *arg)
{
	if (HnswGetSearchCandidateConst(m_node, a)->distance < HnswGetSearchCandidateConst(m_node, b)->distance)
		return -1;

	if (HnswGetSearchCandidateConst(m_node, a)->distance > HnswGetSearchCandidateConst(m_node, b)->distance)
		return 1;

	return 0;
}

/*
 * Init visited
 */
static inline void
InitVisited(char *base, visited_hash * v, bool inMemory, int ef, int m)
{
	if (!inMemory)
		v->tids = tidhash_create(CurrentMemoryContext, ef * m * 2, NULL);
	else if (base != NULL)
		v->offsets = offsethash_create(CurrentMemoryContext, ef * m * 2, NULL);
	else
		v->pointers = pointerhash_create(CurrentMemoryContext, ef * m * 2, NULL);
}

/*
 * Add to visited
 */
static inline void
AddToVisited(char *base, visited_hash * v, HnswElementPtr elementPtr, bool inMemory, bool *found)
{
	if (!inMemory)
	{
		HnswElement element = HnswPtrAccess(base, elementPtr);
		ItemPointerData indextid;

		ItemPointerSet(&indextid, element->blkno, element->offno);
		tidhash_insert(v->tids, indextid, found);
	}
	else if (base != NULL)
	{
		HnswElement element = HnswPtrAccess(base, elementPtr);

		offsethash_insert_hash(v->offsets, HnswPtrOffset(elementPtr), element->hash, found);
	}
	else
	{
		HnswElement element = HnswPtrAccess(base, elementPtr);

		pointerhash_insert_hash(v->pointers, (uintptr_t) HnswPtrPointer(elementPtr), element->hash, found);
	}
}

/*
 * Count element towards ef
 */
static inline bool
CountElement(HnswElement skipElement, HnswElement e)
{
	if (skipElement == NULL)
		return true;

	/* Ensure does not access heaptidsLength during in-memory build */
	pg_memory_barrier();

	/* Keep scan-build happy on Mac x86-64 */
	Assert(e);

	return e->heaptidsLength != 0;
}

/*
 * Load unvisited neighbors from memory
 */
static void
HnswLoadUnvisitedFromMemory(char *base, HnswElement element, HnswUnvisited * unvisited, int *unvisitedLength, visited_hash * v, int lc, HnswNeighborArray * localNeighborhood, Size neighborhoodSize, int maxNeighbors)
{
	/* Get the neighborhood at layer lc */
	HnswNeighborArray *neighborhood = HnswGetNeighbors(base, element, lc);

	/* Copy neighborhood to local memory */
	LWLockAcquire(&element->lock, LW_SHARED);
	memcpy(localNeighborhood, neighborhood, neighborhoodSize);
	LWLockRelease(&element->lock);

	*unvisitedLength = 0;

	for (int i = 0; i < localNeighborhood->length && i < maxNeighbors; i++)
	{
		HnswCandidate *hc = &localNeighborhood->items[i];
		bool		found;

		AddToVisited(base, v, hc->element, true, &found);

		if (!found)
		{
			unvisited[*unvisitedLength].val.element = HnswPtrAccess(base, hc->element);
			unvisited[*unvisitedLength].isAux = false;
			(*unvisitedLength)++;
		}
	}
}

/*
 * Load neighbor index TIDs (base and optionally auxiliary)
 */
static bool
HnswLoadAllNeighborTids(HnswElement element, ItemPointerData *indextids, ItemPointerData *auxIndextids, Relation index, int m, int auxM, int lm, int lc, AttrNumber auxAttno)
{
	Buffer		buf;
	Page		page;
	HnswNeighborTuple ntup;
	int			start;
	int			natts = IndexRelationGetNumberOfAttributes(index);

	buf = ReadBuffer(index, element->neighborPage);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	page = BufferGetPage(buf);

	ntup = (HnswNeighborTuple) PageGetItem(page, PageGetItemId(page, element->neighborOffno));

	/*
	 * Ensure the neighbor tuple has not been deleted or replaced between
	 * index scan iterations
	 */
	if (ntup->version != element->version || ntup->count != (element->level + 2) * m + HnswGetAuxTotalM(auxM, natts))
	{
		UnlockReleaseBuffer(buf);
		return false;
	}

	/* Copy to minimize lock time */
	start = (element->level - lc) * m;
	memcpy(indextids, ntup->indextids + start, lm * sizeof(ItemPointerData));

	if (auxIndextids != NULL && auxAttno != InvalidAttrNumber)
	{
		int am = HnswGetAuxMForAttno(auxM, natts, auxAttno);
		int auxStart = HnswGetAuxOffset(element->level, m, auxM, natts, auxAttno);
		memcpy(auxIndextids, ntup->indextids + auxStart, am * sizeof(ItemPointerData));
	}

	UnlockReleaseBuffer(buf);
	return true;
}

/*
 * Load neighbor index TIDs
 */
bool
HnswLoadNeighborTids(HnswElement element, ItemPointerData *indextids, Relation index, int m, int auxM, int lm, int lc)
{
	return HnswLoadAllNeighborTids(element, indextids, NULL, index, m, auxM, lm, lc, InvalidAttrNumber);
}

/*
 * Load auxiliary neighbor index TIDs
 */
bool
HnswLoadAuxNeighborTids(HnswElement element, ItemPointerData *indextids, Relation index, int m, int auxM, AttrNumber attno)
{
	Buffer		buf;
	Page		page;
	HnswNeighborTuple ntup;
	int			start;
	int			natts = IndexRelationGetNumberOfAttributes(index);
	int			am = HnswGetAuxMForAttno(auxM, natts, attno);

	buf = ReadBuffer(index, element->neighborPage);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	page = BufferGetPage(buf);

	ntup = (HnswNeighborTuple) PageGetItem(page, PageGetItemId(page, element->neighborOffno));

	if (ntup->version != element->version || ntup->count != (element->level + 2) * m + HnswGetAuxTotalM(auxM, natts))
	{
		UnlockReleaseBuffer(buf);
		return false;
	}

	start = HnswGetAuxOffset(element->level, m, auxM, natts, attno);
	memcpy(indextids, ntup->indextids + start, am * sizeof(ItemPointerData));

	UnlockReleaseBuffer(buf);
	return true;
}

/*
 * Load unvisited neighbors from disk
 */
static void
HnswLoadUnvisitedFromDisk(HnswElement element, HnswUnvisited * unvisited, int *unvisitedLength, visited_hash * v, Relation index, int m, int auxM, int lm, int lc, int maxUnvisited, AttrNumber auxAttno)
{
	ItemPointerData indextids[HNSW_MAX_M * 2];
	ItemPointerData auxIndextids[HNSW_MAX_AUX_M];
	int			natts = IndexRelationGetNumberOfAttributes(index);
	int			am = HnswGetAuxMForAttno(auxM, natts, auxAttno);

	*unvisitedLength = 0;

	if (!HnswLoadAllNeighborTids(element, indextids, (auxAttno != InvalidAttrNumber && am > 0) ? auxIndextids : NULL, index, m, auxM, lm, lc, auxAttno))
	{
		return;
	}

	for (int i = 0; i < lm; i++)
	{
		ItemPointer indextid = &indextids[i];
		bool		found;

		if (!ItemPointerIsValid(indextid))
			break;

		tidhash_insert(v->tids, *indextid, &found);

		if (!found && *unvisitedLength < maxUnvisited)
		{
			unvisited[*unvisitedLength].val.indextid = *indextid;
			unvisited[*unvisitedLength].isAux = false;
			(*unvisitedLength)++;
		}
	}

	if (auxAttno != InvalidAttrNumber && am > 0)
	{
		for (int i = 0; i < am; i++)
		{
			ItemPointer indextid = &auxIndextids[i];
			bool		found;

			if (!ItemPointerIsValid(indextid))
				break;

			tidhash_insert(v->tids, *indextid, &found);

			if (!found && *unvisitedLength < maxUnvisited)
			{
				unvisited[*unvisitedLength].val.indextid = *indextid;
				unvisited[*unvisitedLength].isAux = true;
				(*unvisitedLength)++;
			}
		}
	}
}

/*
 * Algorithm 2 from paper
 */
List *
HnswSearchLayer(char *base, HnswQuery * q, List *ep, int ef, int lc, Relation index, HnswSupport * support, int m, bool inserting, HnswElement skipElement, visited_hash * v, pairingheap **discarded, bool initVisited, int64 *tuples, bool inMemory)
{
	List	   *w = NIL;
	pairingheap *C = pairingheap_allocate(CompareNearestCandidates, NULL);
	pairingheap *W = pairingheap_allocate(CompareFurthestCandidates, NULL);
	pairingheap *M = NULL;
	int			wlen = 0;
	int			mlen = 0;
	int			prefilterHops = 0;
	visited_hash vh;
	ListCell   *lc2;
	HnswNeighborArray *localNeighborhood = NULL;
	Size		neighborhoodSize = 0;
	int			lm = HnswGetLayerM(m, lc);
	
	int			natts = inMemory ? 1 : IndexRelationGetNumberOfAttributes(index);
	int			auxM = inMemory ? 0 : HnswGetAuxM(index);
	int			totalAuxM = HnswGetAuxTotalM(auxM, natts);
	int			maxNeighbors = lm + totalAuxM;
	bool		checkFilterScan = !inMemory && lc == 0 && q != NULL && q->scan != NULL && q->scan->numberOfKeys > 0;
	bool		checkFilterInsert = lc == 0 && q != NULL && q->filterAttno != InvalidAttrNumber;
	bool		checkFilter = checkFilterScan || checkFilterInsert;
	bool		prefilter = checkFilter && discarded == NULL;
	AttrNumber	auxAttno = checkFilterScan ? HnswGetAuxScanAttno(q->scan, natts) : (checkFilterInsert ? q->filterAttno : InvalidAttrNumber);
	bool		useAux = auxAttno != InvalidAttrNumber;
	HnswUnvisited *unvisited = palloc(maxNeighbors * sizeof(HnswUnvisited));
	int			unvisitedLength;

	if (prefilter)
		M = pairingheap_allocate(CompareFurthestMatchedCandidates, NULL);

	if (v == NULL)
	{
		v = &vh;
		initVisited = true;
	}

	if (initVisited)
	{
		InitVisited(base, v, inMemory, ef, m);

		if (discarded != NULL)
			*discarded = pairingheap_allocate(CompareNearestDiscardedCandidates, NULL);
	}

	/* Create local memory for neighborhood if needed */
	if (inMemory)
	{
		neighborhoodSize = HNSW_NEIGHBOR_ARRAY_SIZE(lm);
		localNeighborhood = palloc(neighborhoodSize);
	}

	/* Add entry points to v, C, and W */
	foreach(lc2, ep)
	{
		HnswSearchCandidate *sc = (HnswSearchCandidate *) lfirst(lc2);
		bool		found;

		if (initVisited)
		{
			AddToVisited(base, v, sc->element, inMemory, &found);

			/* OK to count elements instead of tuples */
			if (tuples != NULL)
				(*tuples)++;
		}

		pairingheap_add(C, &sc->c_node);
		pairingheap_add(W, &sc->w_node);

		/*
		 * Do not count elements being deleted towards ef when vacuuming. It
		 * would be ideal to do this for inserts as well, but this could
		 * affect insert performance.
		 */
		if (CountElement(skipElement, HnswPtrAccess(base, sc->element)))
		{
			wlen++;

			if (checkFilter)
			{
				/* Re-evaluate for elements from previous layer if needed */
				if (sc->matches_scan)
				{
					if (checkFilterScan)
						sc->matches_scan = HnswElementMatchesScan(HnswPtrAccess(base, sc->element), index, q->scan);
					else if (checkFilterInsert)
						sc->matches_scan = HnswElementMatchesInsertFilter(base, HnswPtrAccess(base, sc->element), index, q);
				}

				if (prefilter && sc->matches_scan)
				{
					pairingheap_add(M, &sc->m_node);
					if (mlen < ef)
						mlen++;
					else
						pairingheap_remove_first(M);
				}
			}
		}
	}

	while (!pairingheap_is_empty(C))
	{
		HnswSearchCandidate *c = HnswGetSearchCandidate(c_node, pairingheap_remove_first(C));
		HnswSearchCandidate *f;
		HnswSearchCandidate *fw;
		HnswElement cElement;

		if (prefilter)
		{
			fw = HnswGetSearchCandidate(w_node, pairingheap_first(W));

			if (mlen >= ef)
			{
				f = HnswGetSearchCandidate(m_node, pairingheap_first(M));
				if (c->distance > f->distance)
					break;
			}
			else if (wlen >= ef && c->distance > fw->distance)
			{
				if (!c->matches_scan)
				{
					int hopLimit = ef;

					if (mlen == 0)
						hopLimit = 10000; /* Allow deep search for the first match */

					if (prefilterHops >= hopLimit)
						break;

					prefilterHops++;
				}
			}
		}
		else
		{
			f = HnswGetSearchCandidate(w_node, pairingheap_first(W));
			if (c->distance > f->distance)
				break;
		}

		cElement = HnswPtrAccess(base, c->element);

		if (inMemory)
			HnswLoadUnvisitedFromMemory(base, cElement, unvisited, &unvisitedLength, v, lc, localNeighborhood, neighborhoodSize, lm);
		else
		{
			bool		currentMatches = useAux && HnswElementMatchesScan(cElement, index, q->scan);

			HnswLoadUnvisitedFromDisk(cElement, unvisited, &unvisitedLength, v, index, m, auxM, lm, lc, maxNeighbors, currentMatches ? auxAttno : InvalidAttrNumber);
		}

		/* OK to count elements instead of tuples */
		if (tuples != NULL)
			(*tuples) += unvisitedLength;

		for (int i = 0; i < unvisitedLength; i++)
		{
			HnswElement eElement;
			HnswSearchCandidate *e;
			double		eDistance;
			bool		isAux = unvisited[i].isAux;
			bool		alwaysAdd = wlen < ef;
			double	   *maxDistance;
			bool		matches = true;
			double		threshold;
			bool		addToW;
			HnswSearchCandidate *fw_eval;
			HnswSearchCandidate *fm_eval;

			f = HnswGetSearchCandidate(w_node, pairingheap_first(W));
			fw_eval = f;
			fm_eval = f;

			if (prefilter)
			{
				fw_eval = HnswGetSearchCandidate(w_node, pairingheap_first(W));
				if (mlen > 0)
					fm_eval = HnswGetSearchCandidate(m_node, pairingheap_first(M));

				if (isAux)
				{
					if (mlen < ef)
						alwaysAdd = true;
				}
				else if (mlen == 0)
				{
					/* Allow some base graph fan-out to find the FIRST match */
					if (wlen >= ef)
						alwaysAdd = true;
				}
			}

			if (inMemory)
			{
				eElement = unvisited[i].val.element;
				eDistance = GetElementDistance(base, eElement, q, support);
				if (checkFilterInsert)
					matches = HnswElementMatchesInsertFilter(base, eElement, index, q);
			}
			else
			{
				ItemPointer indextid = &unvisited[i].val.indextid;
				BlockNumber blkno = ItemPointerGetBlockNumber(indextid);
				OffsetNumber offno = ItemPointerGetOffsetNumber(indextid);

				/* Avoid any allocations if not adding */
				eElement = NULL;
				maxDistance = (alwaysAdd || discarded != NULL) ? NULL : (prefilter && isAux && mlen > 0 ? &fm_eval->distance : &fw_eval->distance);

				if (checkFilterInsert)
				{
					HnswLoadElementImpl(blkno, offno, &eDistance, q, index, support, inserting, maxDistance, &eElement, NULL, NULL);
					if (eElement != NULL)
						matches = HnswElementMatchesInsertFilter(base, eElement, index, q);
				}
				else
				{
					HnswLoadElementImpl(blkno, offno, &eDistance, q, index, support, inserting, maxDistance, &eElement, checkFilterScan ? q->scan : NULL, checkFilterScan ? &matches : NULL);
				}
			}

			/* Make robust to issues */
			if (eElement == NULL || eElement->level < lc)
				continue;

			threshold = (prefilter && isAux && mlen > 0) ? fm_eval->distance : fw_eval->distance;
			addToW = !isAux || wlen < ef || eDistance < fw_eval->distance;

			if (!(eDistance < threshold || alwaysAdd))
			{
				if (discarded != NULL)
				{
					/* Create a new candidate */
					e = HnswInitSearchCandidate(base, eElement, eDistance, matches);
					pairingheap_add(*discarded, &e->w_node);
				}

				continue;
			}

			/* Create a new candidate */
			e = HnswInitSearchCandidate(base, eElement, eDistance, matches);
			pairingheap_add(C, &e->c_node);

			/* Only add to W if it's a spatial base node, or if we haven't filled W yet */
			if (addToW)
				pairingheap_add(W, &e->w_node);

			/*
			 * Do not count elements being deleted towards ef when vacuuming.
			 * It would be ideal to do this for inserts as well, but this
			 * could affect insert performance.
			 */
			if (CountElement(skipElement, eElement))
			{
				if (addToW)
				{
					wlen++;

					/* No need to decrement wlen */
					if (wlen > ef)
					{
						HnswSearchCandidate *d = HnswGetSearchCandidate(w_node, pairingheap_remove_first(W));

						if (discarded != NULL)
							pairingheap_add(*discarded, &d->w_node);
					}
				}

				if (prefilter && matches)
				{
					pairingheap_add(M, &e->m_node);
					if (mlen < ef)
						mlen++;
					else
						pairingheap_remove_first(M);
				}
			}
		}
	}

	/* Add each element to w */
	if (prefilter)
	{
		while (!pairingheap_is_empty(M))
		{
			HnswSearchCandidate *sc = HnswGetSearchCandidate(m_node, pairingheap_remove_first(M));

			w = lappend(w, sc);
		}
	}
	else
	{
		while (!pairingheap_is_empty(W))
		{
			HnswSearchCandidate *sc = HnswGetSearchCandidate(w_node, pairingheap_remove_first(W));

			w = lappend(w, sc);
		}
	}

	return w;
}

/*
 * Compare candidate distances with pointer tie-breaker
 */
static int
CompareCandidateDistances(const ListCell *a, const ListCell *b)
{
	HnswCandidate *hca = lfirst(a);
	HnswCandidate *hcb = lfirst(b);

	if (hca->distance < hcb->distance)
		return 1;

	if (hca->distance > hcb->distance)
		return -1;

	if (HnswPtrPointer(hca->element) < HnswPtrPointer(hcb->element))
		return 1;

	if (HnswPtrPointer(hca->element) > HnswPtrPointer(hcb->element))
		return -1;

	return 0;
}

/*
 * Compare candidate distances with offset tie-breaker
 */
static int
CompareCandidateDistancesOffset(const ListCell *a, const ListCell *b)
{
	HnswCandidate *hca = lfirst(a);
	HnswCandidate *hcb = lfirst(b);

	if (hca->distance < hcb->distance)
		return 1;

	if (hca->distance > hcb->distance)
		return -1;

	if (HnswPtrOffset(hca->element) < HnswPtrOffset(hcb->element))
		return 1;

	if (HnswPtrOffset(hca->element) > HnswPtrOffset(hcb->element))
		return -1;

	return 0;
}

/*
 * Check if an element is closer to q than any element from R
 */
static bool
CheckElementCloser(char *base, HnswCandidate * e, List *r, HnswSupport * support)
{
	HnswElement eElement = HnswPtrAccess(base, e->element);
	Datum		eValue = HnswGetValue(base, eElement);
	ListCell   *lc2;

	foreach(lc2, r)
	{
		HnswCandidate *ri = lfirst(lc2);
		HnswElement riElement = HnswPtrAccess(base, ri->element);
		Datum		riValue = HnswGetValue(base, riElement);
		float		distance = HnswGetDistance(eValue, riValue, support);

		if (distance <= e->distance)
			return false;
	}

	return true;
}

/*
 * Algorithm 4 from paper
 */
static List *
SelectNeighbors(char *base, List *c, int lm, HnswSupport * support, bool *closerSet, HnswCandidate * newCandidate, HnswCandidate * *pruned, bool sortCandidates)
{
	List	   *r = NIL;
	List	   *w = list_copy(c);
	HnswCandidate **wd;
	int			wdlen = 0;
	int			wdoff = 0;
	bool		mustCalculate = !(*closerSet);
	List	   *added = NIL;
	bool		removedAny = false;

	if (list_length(w) <= lm)
		return w;

	wd = palloc(sizeof(HnswCandidate *) * list_length(w));

	/* Ensure order of candidates is deterministic for closer caching */
	if (sortCandidates)
	{
		if (base == NULL)
			list_sort(w, CompareCandidateDistances);
		else
			list_sort(w, CompareCandidateDistancesOffset);
	}

	while (list_length(w) > 0 && list_length(r) < lm)
	{
		/* Assumes w is already ordered desc */
		HnswCandidate *e = llast(w);

		w = list_delete_last(w);

		/* Use previous state of r and wd to skip work when possible */
		if (mustCalculate)
			e->closer = CheckElementCloser(base, e, r, support);
		else if (list_length(added) > 0)
		{
			/* Keep Valgrind happy for in-memory, parallel builds */
			if (base != NULL)
				VALGRIND_MAKE_MEM_DEFINED(&e->closer, 1);

			/*
			 * If the current candidate was closer, we only need to compare it
			 * with the other candidates that we have added.
			 */
			if (e->closer)
			{
				e->closer = CheckElementCloser(base, e, added, support);

				if (!e->closer)
					removedAny = true;
			}
			else
			{
				/*
				 * If we have removed any candidates from closer, a candidate
				 * that was not closer earlier might now be.
				 */
				if (removedAny)
				{
					e->closer = CheckElementCloser(base, e, r, support);
					if (e->closer)
						added = lappend(added, e);
				}
			}
		}
		else if (e == newCandidate)
		{
			e->closer = CheckElementCloser(base, e, r, support);
			if (e->closer)
				added = lappend(added, e);
		}

		/* Keep Valgrind happy for in-memory, parallel builds */
		if (base != NULL)
			VALGRIND_MAKE_MEM_DEFINED(&e->closer, 1);

		if (e->closer)
			r = lappend(r, e);
		else
			wd[wdlen++] = e;
	}

	/* Cached value can only be used in future if sorted deterministically */
	*closerSet = sortCandidates;

	/* Keep pruned connections */
	while (wdoff < wdlen && list_length(r) < lm)
		r = lappend(r, wd[wdoff++]);

	/* Return pruned for update connections */
	if (pruned != NULL)
	{
		if (wdoff < wdlen)
			*pruned = wd[wdoff];
		else
			*pruned = linitial(w);
	}

	return r;
}

/*
 * Add connections
 */
static void
AddConnections(char *base, HnswElement element, List *neighbors, int lc)
{
	ListCell   *lc2;
	HnswNeighborArray *a = HnswGetNeighbors(base, element, lc);

	foreach(lc2, neighbors)
		a->items[a->length++] = *((HnswCandidate *) lfirst(lc2));
}

/*
 * Update connections
 */
void
HnswUpdateConnection(char *base, HnswNeighborArray * neighbors, HnswElement newElement, float distance, int lm, int *updateIdx, Relation index, HnswSupport * support)
{
	HnswCandidate newHc;

	HnswPtrStore(base, newHc.element, newElement);
	newHc.distance = distance;

	if (neighbors->length < lm)
	{
		neighbors->items[neighbors->length++] = newHc;

		/* Track update */
		if (updateIdx != NULL)
			*updateIdx = -2;
	}
	else
	{
		/* Shrink connections */
		List	   *c = NIL;
		HnswCandidate *pruned = NULL;

		/* Add candidates */
		for (int i = 0; i < neighbors->length; i++)
			c = lappend(c, &neighbors->items[i]);
		c = lappend(c, &newHc);

		SelectNeighbors(base, c, lm, support, &neighbors->closerSet, &newHc, &pruned, true);

		/* Should not happen */
		if (pruned == NULL)
			return;

		/* Find and replace the pruned element */
		for (int i = 0; i < neighbors->length; i++)
		{
			if (HnswPtrEqual(base, neighbors->items[i].element, pruned->element))
			{
				neighbors->items[i] = newHc;

				/* Track update */
				if (updateIdx != NULL)
					*updateIdx = i;

				break;
			}
		}
	}
}

/*
 * Remove elements being deleted or skipped
 */
static List *
RemoveElements(char *base, List *w, HnswElement skipElement)
{
	ListCell   *lc2;
	List	   *w2 = NIL;

	/* Ensure does not access heaptidsLength during in-memory build */
	pg_memory_barrier();

	foreach(lc2, w)
	{
		HnswCandidate *hc = (HnswCandidate *) lfirst(lc2);
		HnswElement hce = HnswPtrAccess(base, hc->element);

		/* Skip self for vacuuming update */
		if (skipElement != NULL && hce->blkno == skipElement->blkno && hce->offno == skipElement->offno)
			continue;

		if (hce->heaptidsLength != 0)
			w2 = lappend(w2, hc);
	}

	return w2;
}

/*
 * Precompute hash
 */
static void
PrecomputeHash(char *base, HnswElement element)
{
	HnswElementPtr ptr;

	HnswPtrStore(base, ptr, element);

	if (base == NULL)
		element->hash = hash_pointer((uintptr_t) HnswPtrPointer(ptr));
	else
		element->hash = hash_offset(HnswPtrOffset(ptr));
}

/*
 * Algorithm 1 from paper
 */
void
HnswFindElementNeighbors(char *base, HnswElement element, HnswElement entryPoint, Relation index, HnswSupport * support, int m, int efConstruction, bool existing, bool inMemory)
{
	List	   *ep;
	List	   *w;
	int			level = element->level;
	int			entryLevel;
	HnswQuery	q;
	HnswElement skipElement = existing ? element : NULL;
	

	q.value = HnswGetValue(base, element);
	q.scan = NULL;
	q.filterAttno = InvalidAttrNumber;

	/* Precompute hash */
	if (inMemory)
		PrecomputeHash(base, element);

	/* No neighbors if no entry point */
	if (entryPoint == NULL)
		return;

	/* Get entry point and level */
	ep = list_make1(HnswEntryCandidate(base, entryPoint, &q, index, support, true, inMemory));
	entryLevel = entryPoint->level;

	/* 1st phase: greedy search to insert level */
	for (int lc = entryLevel; lc >= level + 1; lc--)
	{
		w = HnswSearchLayer(base, &q, ep, 1, lc, index, support, m, true, skipElement, NULL, NULL, true, NULL, inMemory);
		ep = w;
	}

	if (level > entryLevel)
		level = entryLevel;

	/* Add one for existing element */
	if (existing)
		efConstruction++;

	/* 2nd phase */
	for (int lc = level; lc >= 0; lc--)
	{
		int			lm = HnswGetLayerM(m, lc);
		List	   *neighbors;
		List	   *lw = NIL;
		ListCell   *lc2;

		w = HnswSearchLayer(base, &q, ep, efConstruction, lc, index, support, m, true, skipElement, NULL, NULL, true, NULL, inMemory);

		/* Convert search candidates to candidates */
		foreach(lc2, w)
		{
			HnswSearchCandidate *sc = lfirst(lc2);
			HnswCandidate *hc = palloc(sizeof(HnswCandidate));

			hc->element = sc->element;
			hc->distance = sc->distance;

			lw = lappend(lw, hc);
		}

		/* Elements being deleted or skipped can help with search */
		/* but should be removed before selecting neighbors */
		if (!inMemory)
			lw = RemoveElements(base, lw, skipElement);

		/*
		 * Candidates are sorted, but not deterministically. Could set
		 * sortCandidates to true for in-memory builds to enable closer
		 * caching, but there does not seem to be a difference in performance.
		 */
		neighbors = SelectNeighbors(base, lw, lm, support, &HnswGetNeighbors(base, element, lc)->closerSet, NULL, NULL, false);

		AddConnections(base, element, neighbors, lc);

		ep = w;
	}
}

PGDLLEXPORT Datum l2_normalize(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum halfvec_l2_normalize(PG_FUNCTION_ARGS);
PGDLLEXPORT Datum sparsevec_l2_normalize(PG_FUNCTION_ARGS);

static void
SparsevecCheckValue(Pointer v)
{
	SparseVector *vec = (SparseVector *) v;

	if (vec->nnz > HNSW_MAX_NNZ)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("sparsevec cannot have more than %d non-zero elements for hnsw index", HNSW_MAX_NNZ)));
}

/*
 * Get type info
 */
const		HnswTypeInfo *
HnswGetTypeInfo(Relation index)
{
	FmgrInfo   *procinfo = HnswOptionalProcInfo(index, HNSW_TYPE_INFO_PROC);

	if (procinfo == NULL)
	{
		static const HnswTypeInfo typeInfo = {
			.maxDimensions = HNSW_MAX_DIM,
			.normalize = l2_normalize,
			.checkValue = NULL
		};

		return (&typeInfo);
	}
	else
		return (const HnswTypeInfo *) DatumGetPointer(FunctionCall0Coll(procinfo, InvalidOid));
}

FUNCTION_PREFIX PG_FUNCTION_INFO_V1(hnsw_halfvec_support);
Datum
hnsw_halfvec_support(PG_FUNCTION_ARGS)
{
	static const HnswTypeInfo typeInfo = {
		.maxDimensions = HNSW_MAX_DIM * 2,
		.normalize = halfvec_l2_normalize,
		.checkValue = NULL
	};

	PG_RETURN_POINTER(&typeInfo);
}

FUNCTION_PREFIX PG_FUNCTION_INFO_V1(hnsw_bit_support);
Datum
hnsw_bit_support(PG_FUNCTION_ARGS)
{
	static const HnswTypeInfo typeInfo = {
		.maxDimensions = HNSW_MAX_DIM * 32,
		.normalize = NULL,
		.checkValue = NULL
	};

	PG_RETURN_POINTER(&typeInfo);
}

FUNCTION_PREFIX PG_FUNCTION_INFO_V1(hnsw_sparsevec_support);
Datum
hnsw_sparsevec_support(PG_FUNCTION_ARGS)
{
	static const HnswTypeInfo typeInfo = {
		.maxDimensions = SPARSEVEC_MAX_DIM,
		.normalize = sparsevec_l2_normalize,
		.checkValue = SparsevecCheckValue
	};

	PG_RETURN_POINTER(&typeInfo);
}
