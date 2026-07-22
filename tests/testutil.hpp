#ifndef HPP_TESTUTIL
#define HPP_TESTUTIL

/* testutil.hpp
 * ============
 * Shared helpers for the mp-math correctness tests and benchmarks:
 *   - OpenCL boilerplate (context/device selection, program build from
 *     keccak.cl + profanity.cl + tests/harness.cl, mirroring profanity.cpp)
 *   - Host-side 256/512-bit reference arithmetic used to verify the kernels
 *     against an independent implementation.
 */

#define CL_TARGET_OPENCL_VERSION 120

#if defined(__APPLE__) || defined(__MACOSX)
#include <OpenCL/cl.h>
#else
#include <CL/cl.h>
#endif

#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "../types.hpp"

/* ------------------------------------------------------------------------ */
/* OpenCL helpers                                                            */
/* ------------------------------------------------------------------------ */

// The value of PROFANITY_INVERSE_SIZE does not affect the mp_* math functions
// under test; a small value keeps kernel compilation fast on CPU OpenCL
// implementations like PoCL.
static const char * const g_buildOptions = "-D PROFANITY_INVERSE_SIZE=2 -D PROFANITY_MAX_SCORE=40";

inline void clCheck(const cl_int err, const char * const what) {
	if (err != CL_SUCCESS) {
		std::cerr << "OpenCL error " << err << " during: " << what << std::endl;
		std::exit(1);
	}
}

// Reads a file, looking in the current directory first and then one level up,
// so the binaries can be run both from the repository root and from tests/.
inline std::string readFile(const std::string & name) {
	for (const char * const prefix : { "", "../" }) {
		std::ifstream in(prefix + name, std::ios::in | std::ios::binary);
		if (in) {
			std::string contents;
			in.seekg(0, std::ios::end);
			contents.resize(in.tellg());
			in.seekg(0, std::ios::beg);
			in.read(&contents[0], contents.size());
			return contents;
		}
	}

	std::cerr << "Could not open " << name << " (run from the repository root or from tests/)" << std::endl;
	std::exit(1);
}

struct ClSetup {
	cl_device_id device;
	cl_context context;
	cl_command_queue queue;
	cl_program program;
};

inline ClSetup clSetup() {
	ClSetup s;

	cl_uint numPlatforms = 0;
	clCheck(clGetPlatformIDs(0, NULL, &numPlatforms), "clGetPlatformIDs(count)");
	if (numPlatforms == 0) {
		std::cerr << "No OpenCL platforms found" << std::endl;
		std::exit(1);
	}

	std::vector<cl_platform_id> platforms(numPlatforms);
	clCheck(clGetPlatformIDs(numPlatforms, platforms.data(), NULL), "clGetPlatformIDs");

	// Use the first device of the first platform that has one
	s.device = NULL;
	for (cl_platform_id platform : platforms) {
		cl_uint numDevices = 0;
		if (clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 0, NULL, &numDevices) == CL_SUCCESS && numDevices > 0) {
			clCheck(clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 1, &s.device, NULL), "clGetDeviceIDs");
			break;
		}
	}
	if (s.device == NULL) {
		std::cerr << "No OpenCL devices found" << std::endl;
		std::exit(1);
	}

	char deviceName[256] = { 0 };
	clGetDeviceInfo(s.device, CL_DEVICE_NAME, sizeof(deviceName) - 1, deviceName, NULL);
	std::cout << "Device: " << deviceName << std::endl;

	cl_int errorCode;
	s.context = clCreateContext(NULL, 1, &s.device, NULL, NULL, &errorCode);
	clCheck(errorCode, "clCreateContext");
	s.queue = clCreateCommandQueue(s.context, s.device, 0, &errorCode);
	clCheck(errorCode, "clCreateCommandQueue");

	// Same source assembly as profanity.cpp, plus the test harness
	const std::string strKeccak = readFile("keccak.cl");
	const std::string strVanity = readFile("profanity.cl");
	const std::string strHarness = readFile("tests/harness.cl");
	const char * szKernels[] = { strKeccak.c_str(), strVanity.c_str(), strHarness.c_str() };

	s.program = clCreateProgramWithSource(s.context, sizeof(szKernels) / sizeof(char *), szKernels, NULL, &errorCode);
	clCheck(errorCode, "clCreateProgramWithSource");

	if (clBuildProgram(s.program, 1, &s.device, g_buildOptions, NULL, NULL) != CL_SUCCESS) {
		size_t sizeLog = 0;
		clGetProgramBuildInfo(s.program, s.device, CL_PROGRAM_BUILD_LOG, 0, NULL, &sizeLog);
		std::string log(sizeLog, '\0');
		clGetProgramBuildInfo(s.program, s.device, CL_PROGRAM_BUILD_LOG, sizeLog, &log[0], NULL);
		std::cerr << "Kernel build failed:" << std::endl << log << std::endl;
		std::exit(1);
	}

	return s;
}

/* ------------------------------------------------------------------------ */
/* Host-side reference arithmetic (independent of the OpenCL code)           */
/* ------------------------------------------------------------------------ */
/* Numbers use the same representation as mp_number: little-endian 32-bit
 * words. All arithmetic below uses plain 64-bit accumulators, no compiler
 * extensions. */

// secp256k1 prime p = 2^256 - 2^32 - 977
static const mp_number g_p = { { 0xfffffc2f, 0xfffffffe, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff } };

inline bool mpEqual(const mp_number & a, const mp_number & b) {
	for (int i = 0; i < MP_NWORDS; ++i) {
		if (a.d[i] != b.d[i]) {
			return false;
		}
	}
	return true;
}

// a >= b
inline bool mpGte(const mp_number & a, const mp_number & b) {
	for (int i = MP_NWORDS - 1; i >= 0; --i) {
		if (a.d[i] != b.d[i]) {
			return a.d[i] > b.d[i];
		}
	}
	return true;
}

// a -= b (mod 2^256)
inline void mpSub(mp_number & a, const mp_number & b) {
	uint64_t borrow = 0;
	for (int i = 0; i < MP_NWORDS; ++i) {
		const uint64_t t = (uint64_t)a.d[i] - b.d[i] - borrow;
		a.d[i] = (uint32_t)t;
		borrow = (t >> 32) & 1;
	}
}

inline std::string mpToHex(const mp_number & a) {
	static const char digits[] = "0123456789abcdef";
	std::string out = "0x";
	for (int i = MP_NWORDS - 1; i >= 0; --i) {
		for (int shift = 28; shift >= 0; shift -= 4) {
			out += digits[(a.d[i] >> shift) & 0xF];
		}
	}
	return out;
}

// Reference for mp_mul_mod_word_sub:
//   r' = (r - w * p - (withModHigher ? (p << 32) : 0)) mod 2^256
inline mp_number refMulModWordSub(const mp_number & r, const uint32_t w, const bool withModHigher) {
	// t = w * p + (withModHigher ? p << 32 : 0), computed mod 2^256
	mp_number t = { { 0 } };
	uint64_t carry = 0;
	for (int i = 0; i < MP_NWORDS; ++i) {
		uint64_t acc = (uint64_t)g_p.d[i] * w + carry;
		if (withModHigher && i > 0) {
			acc += g_p.d[i - 1];
		}
		t.d[i] = (uint32_t)acc;
		carry = acc >> 32;
	}

	mp_number out = r;
	mpSub(out, t);
	return out;
}

// Full 512-bit product of two 256-bit numbers (schoolbook)
inline void refMul512(const mp_number & a, const mp_number & b, uint32_t out[MP_NWORDS * 2]) {
	for (int i = 0; i < MP_NWORDS * 2; ++i) {
		out[i] = 0;
	}

	for (int i = 0; i < MP_NWORDS; ++i) {
		uint64_t carry = 0;
		for (int j = 0; j < MP_NWORDS; ++j) {
			const uint64_t t = (uint64_t)a.d[i] * b.d[j] + out[i + j] + carry;
			out[i + j] = (uint32_t)t;
			carry = t >> 32;
		}
		out[i + MP_NWORDS] = (uint32_t)carry;
	}
}

// Reduces a value of up to 544 bits (17 words) modulo p.
// Uses the same identity as the optimization under test, on the host side:
// v = hi * 2^256 + lo == hi * pmod + lo (mod p), where pmod = 2^32 + 977.
inline mp_number refModP(const uint32_t * const v, const int numWords) {
	uint32_t cur[MP_NWORDS * 2 + 1] = { 0 };
	for (int i = 0; i < numWords; ++i) {
		cur[i] = v[i];
	}

	for (;;) {
		bool hasHigh = false;
		for (int i = MP_NWORDS; i < MP_NWORDS * 2 + 1; ++i) {
			if (cur[i] != 0) {
				hasHigh = true;
				break;
			}
		}
		if (!hasHigh) {
			break;
		}

		// next = lo + hi * 977 + (hi << 32)
		uint32_t next[MP_NWORDS * 2 + 1] = { 0 };
		uint64_t carry = 0;
		for (int i = 0; i < MP_NWORDS * 2 + 1; ++i) {
			uint64_t acc = carry;
			if (i < MP_NWORDS) {
				acc += cur[i]; // lo
			}
			const int hiIdx = MP_NWORDS + i;
			if (hiIdx < MP_NWORDS * 2 + 1) {
				acc += (uint64_t)cur[hiIdx] * 977; // hi * 977
			}
			if (i >= 1 && MP_NWORDS + i - 1 < MP_NWORDS * 2 + 1) {
				acc += cur[MP_NWORDS + i - 1]; // hi << 32
			}
			next[i] = (uint32_t)acc;
			carry = acc >> 32;
		}
		for (int i = 0; i < MP_NWORDS * 2 + 1; ++i) {
			cur[i] = next[i];
		}
	}

	mp_number out;
	for (int i = 0; i < MP_NWORDS; ++i) {
		out.d[i] = cur[i];
	}
	while (mpGte(out, g_p)) {
		mpSub(out, g_p);
	}
	return out;
}

// (x * y) mod p via the reference implementation
inline mp_number refMulModP(const mp_number & x, const mp_number & y) {
	uint32_t product[MP_NWORDS * 2];
	refMul512(x, y, product);
	return refModP(product, MP_NWORDS * 2);
}

// value mod p for a 256-bit value
inline mp_number refModP256(const mp_number & v) {
	return refModP(v.d, MP_NWORDS);
}

#endif /* HPP_TESTUTIL */
