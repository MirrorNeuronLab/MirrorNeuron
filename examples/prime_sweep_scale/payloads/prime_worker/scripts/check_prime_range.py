#!/usr/bin/env python3
import json
import math
import sys


def is_prime(number: int) -> bool:
    if number < 2:
        return False
    if number == 2:
        return True
    if number % 2 == 0:
        return False

    limit = int(math.isqrt(number))
    for divisor in range(3, limit + 1, 2):
        if number % divisor == 0:
            return False

    return True


def primes_in_range(range_start: int, range_end: int) -> list[int]:
    return [number for number in range(range_start, range_end + 1) if is_prime(number)]


def main() -> None:
    worker_id = sys.argv[1]
    range_start = int(sys.argv[2])
    range_end = int(sys.argv[3])
    primes = primes_in_range(range_start, range_end)

    print(
        json.dumps(
            {
                "worker_id": worker_id,
                "range_start": range_start,
                "range_end": range_end,
                "checked_numbers": range_end - range_start + 1,
                "prime_count": len(primes),
                "primes": primes,
            }
        )
    )


if __name__ == "__main__":
    main()
