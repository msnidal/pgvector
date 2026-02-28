#!/usr/bin/env python3
import sys
import random
import csv
import argparse

def generate_zipf_weights(n, alpha):
    return [1.0 / (i ** alpha) for i in range(1, n + 1)]

def main():
    parser = argparse.ArgumentParser(description="Generate Zipfian skewed data for ACORN HNSW benchmarking")
    parser.add_argument('--rows', type=int, default=100000)
    parser.add_argument('--queries', type=int, default=1000)
    parser.add_argument('--dim', type=int, default=128)
    parser.add_argument('--low-card', type=int, default=5)
    parser.add_argument('--med-card', type=int, default=50)
    parser.add_argument('--high-card', type=int, default=500)
    parser.add_argument('--score-card', type=int, default=1000)
    parser.add_argument('--skew-alpha', type=float, default=1.5)
    parser.add_argument('--items-out', type=str, required=True)
    parser.add_argument('--queries-out', type=str, required=True)
    args = parser.parse_args()

    # Pre-calculate Zipf distributions
    w_low = generate_zipf_weights(args.low_card, args.skew_alpha)
    p_low = list(range(args.low_card))
    
    w_med = generate_zipf_weights(args.med_card, args.skew_alpha)
    p_med = list(range(args.med_card))
    
    w_high = generate_zipf_weights(args.high_card, args.skew_alpha)
    p_high = list(range(args.high_card))
    
    w_score = generate_zipf_weights(args.score_card, args.skew_alpha)
    p_score = list(range(args.score_card))

    print(f"Generating {args.rows} items...")
    with open(args.items_out, 'w', newline='') as f:
        writer = csv.writer(f)
        for i in range(1, args.rows + 1):
            emb = "[" + ",".join(f"{random.random():.6f}" for _ in range(args.dim)) + "]"
            c_low = random.choices(p_low, weights=w_low)[0]
            c_med = random.choices(p_med, weights=w_med)[0]
            c_high = random.choices(p_high, weights=w_high)[0]
            score = random.choices(p_score, weights=w_score)[0]
            writer.writerow([i, emb, c_low, c_med, c_high, score])

    print(f"Generating {args.queries} queries...")
    with open(args.queries_out, 'w', newline='') as f:
        writer = csv.writer(f)
        for i in range(1, args.queries + 1):
            emb = "[" + ",".join(f"{random.random():.6f}" for _ in range(args.dim)) + "]"
            c_low = random.choices(p_low, weights=w_low)[0]
            c_med = random.choices(p_med, weights=w_med)[0]
            c_high = random.choices(p_high, weights=w_high)[0]
            score = random.choices(p_score, weights=w_score)[0]
            score_lo = max(0, score - 10)
            score_hi = min(args.score_card - 1, score + 10)
            writer.writerow([i, emb, c_low, c_med, c_high, score, score_lo, score_hi])

if __name__ == '__main__':
    main()
