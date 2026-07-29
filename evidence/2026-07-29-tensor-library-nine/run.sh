#!/bin/bash
# Reproduce the tensor-library-nine sweeps. From core/:
#   cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && cmake --build build --target topopt -j
#   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
#       tests/harness/tensor_library_nine_probe.cpp build/libtopopt.a -o build/tln_probe
# then per topology (parallelize across topologies; each is single-threaded):
#   TOPOPT_LATTICE_CSV_DIR=out TOPOPT_TL_VFS=0.08,0.10,0.15,0.20,0.30,0.40,0.50,0.60 \
#     TOPOPT_TL_VPCS=48,64 ./build/tln_probe sweep <topo>
# topologies: sc bcc fcc diamond kelvin rhombic octet bccz fccz reentrant
# self-check (bar B1): ./build/tln_probe self <topo>
