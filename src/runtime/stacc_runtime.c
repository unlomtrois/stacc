/* Minimal runtime for natively compiled Stacy programs.
 * Compiled and linked together with the generated .s by `zig cc`. */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

void stacc_rt_print_i64(long long v) { printf("%lld\n", v); }

void stacc_rt_print_f64(double v) { printf("%.15g\n", v); }

void stacc_rt_print_bool(long long v) { puts(v ? "true" : "false"); }

_Noreturn void stacc_rt_div0(void) {
    fprintf(stderr, "error: DivisionByZero\n");
    exit(1);
}

_Noreturn void stacc_rt_overflow(void) {
    fprintf(stderr, "error: Overflow\n");
    exit(1);
}

long long stacc_rt_powi(long long base, long long exp) {
    if (exp < 0) {
        fprintf(stderr, "error: Underflow\n");
        exit(1);
    }
    long long result = 1;
    while (exp > 0) {
        if (exp & 1) {
            if (__builtin_mul_overflow(result, base, &result)) stacc_rt_overflow();
        }
        exp >>= 1;
        if (exp > 0) {
            if (__builtin_mul_overflow(base, base, &base)) stacc_rt_overflow();
        }
    }
    return result;
}

double stacc_rt_pow(double a, double b) { return pow(a, b); }

_Noreturn void stacc_rt_missing_return(void) {
    fprintf(stderr, "error: MissingReturn\n");
    exit(1);
}
