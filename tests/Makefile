# Builds the mp-math correctness tests and benchmarks. Mirrors the style of the
# main Makefile. Requires an OpenCL runtime; on machines without a GPU, PoCL
# (http://portablecl.org, e.g. `apt install pocl-opencl-icd`) works fine.
#
# Usage:
#   make
#   ./test_correctness.x64 [num_random_cases]
#   ./bench_mod_mul.x64 [global_size] [iterations] [repetitions]

CC=g++
CDEFINES=
EXECUTABLES=test_correctness.x64 bench_mod_mul.x64

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	LDFLAGS=-framework OpenCL
	CFLAGS=-std=c++11 -Wall -O2
else
	LDFLAGS=-lOpenCL
	CFLAGS=-std=c++11 -Wall -O2
endif

all: $(EXECUTABLES)

test_correctness.x64: test_correctness.cpp testutil.hpp ../types.hpp
	$(CC) $(CFLAGS) $(CDEFINES) test_correctness.cpp $(LDFLAGS) -o $@

bench_mod_mul.x64: bench_mod_mul.cpp testutil.hpp ../types.hpp
	$(CC) $(CFLAGS) $(CDEFINES) bench_mod_mul.cpp $(LDFLAGS) -o $@

clean:
	rm -rf $(EXECUTABLES)
