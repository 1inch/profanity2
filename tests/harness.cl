/* harness.cl
 * ==========
 * Test/benchmark harness appended after the multiprecision section of profanity.cl.
 *
 * Contains:
 *   1. The pre-PR#49 ("old") implementations of mp_mul_mod_word_sub and mp_mod_mul,
 *      kept verbatim as a reference to test bit-exact equivalence against the
 *      optimized versions that now live in profanity.cl.
 *   2. Thin __kernel wrappers so the host-side tests can invoke both versions.
 *   3. Benchmark kernels that run a dependency-chained sequence of modular
 *      multiplications, so throughput of old vs new can be compared.
 */

/* ------------------------------------------------------------------------ */
/* Reference (pre-PR#49) implementations, verbatim from master              */
/* ------------------------------------------------------------------------ */

void mp_mul_mod_word_sub_old(mp_number * const r, const mp_word w, const bool withModHigher) {
	// Having these numbers declared here instead of using the global values in __constant address space seems to lead
	// to better optimizations by the compiler on my GTX 1070.
	mp_number mod = { { 0xfffffc2f, 0xfffffffe, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff} };
	mp_number modhigher = { {0x00000000, 0xfffffc2f, 0xfffffffe, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff} };

	mp_word cM = 0; // Carry for multiplication
	mp_word cS = 0; // Carry for subtraction
	mp_word tS = 0; // Temporary storage for subtraction
	mp_word tM = 0; // Temporary storage for multiplication
	mp_word cA = 0; // Carry for addition of modhigher

	for (mp_word i = 0; i < MP_WORDS; ++i) {
		tM = (mod.d[i] * w + cM);
		cM = mul_hi(mod.d[i], w) + (tM < cM);

		tM += (withModHigher ? modhigher.d[i] : 0) + cA;
		cA = tM < (withModHigher ? modhigher.d[i] : 0) ? 1 : (tM == (withModHigher ? modhigher.d[i] : 0) ? cA : 0);

		tS = r->d[i] - tM - cS;
		cS = tS > r->d[i] ? 1 : (tS == r->d[i] ? cS : 0);

		r->d[i] = tS;
	}
}

// Copy of mp_mod_mul from profanity.cl that calls the old subtraction routine.
void mp_mod_mul_old(mp_number * const r, const mp_number * const X, const mp_number * const Y) {
	mp_number Z = { {0} };
	mp_word extraWord;

	for (int i = MP_WORDS - 1; i >= 0; --i) {
		// Z = Z * 2^32
		extraWord = Z.d[7]; Z.d[7] = Z.d[6]; Z.d[6] = Z.d[5]; Z.d[5] = Z.d[4]; Z.d[4] = Z.d[3]; Z.d[3] = Z.d[2]; Z.d[2] = Z.d[1]; Z.d[1] = Z.d[0]; Z.d[0] = 0;

		// Z = Z + X * Y_i
		bool overflow = mp_mul_word_add_extra(&Z, X, Y->d[i], &extraWord);

		// Z = Z - qM
		mp_mul_mod_word_sub_old(&Z, extraWord, overflow);
	}

	*r = Z;
}

/* ------------------------------------------------------------------------ */
/* Correctness / equivalence test kernels                                   */
/* ------------------------------------------------------------------------ */

__kernel void k_mul_mod_word_sub_new(__global mp_number * const r, __global const uint * const w, __global const uint * const withModHigher) {
	const size_t id = get_global_id(0);
	mp_number x = r[id];
	mp_mul_mod_word_sub(&x, w[id], withModHigher[id] != 0);
	r[id] = x;
}

__kernel void k_mul_mod_word_sub_old(__global mp_number * const r, __global const uint * const w, __global const uint * const withModHigher) {
	const size_t id = get_global_id(0);
	mp_number x = r[id];
	mp_mul_mod_word_sub_old(&x, w[id], withModHigher[id] != 0);
	r[id] = x;
}

__kernel void k_mod_mul_new(__global const mp_number * const X, __global const mp_number * const Y, __global mp_number * const R) {
	const size_t id = get_global_id(0);
	mp_number x = X[id];
	mp_number y = Y[id];
	mp_number r;
	mp_mod_mul(&r, &x, &y);
	R[id] = r;
}

__kernel void k_mod_mul_old(__global const mp_number * const X, __global const mp_number * const Y, __global mp_number * const R) {
	const size_t id = get_global_id(0);
	mp_number x = X[id];
	mp_number y = Y[id];
	mp_number r;
	mp_mod_mul_old(&r, &x, &y);
	R[id] = r;
}

/* ------------------------------------------------------------------------ */
/* Benchmark kernels                                                        */
/* ------------------------------------------------------------------------ */
/* Each work item performs `iterations` chained modular multiplications:
 * x = x * y (mod p). The data dependency between iterations prevents the
 * compiler from removing or reordering the work. The final x is written back
 * so nothing is dead code (and so the host can cross-check old vs new). */

__kernel void bench_mod_mul_new(__global mp_number * const X, __global const mp_number * const Y, const uint iterations) {
	const size_t id = get_global_id(0);
	mp_number x = X[id];
	const mp_number y = Y[id];

	for (uint i = 0; i < iterations; ++i) {
		mp_mod_mul(&x, &x, &y);
	}

	X[id] = x;
}

__kernel void bench_mod_mul_old(__global mp_number * const X, __global const mp_number * const Y, const uint iterations) {
	const size_t id = get_global_id(0);
	mp_number x = X[id];
	const mp_number y = Y[id];

	for (uint i = 0; i < iterations; ++i) {
		mp_mod_mul_old(&x, &x, &y);
	}

	X[id] = x;
}
