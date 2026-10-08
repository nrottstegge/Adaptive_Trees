cmake_minimum_required(VERSION 3.22)

project(adaptive_octree LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 20)

if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES 120)
endif()

include(CTest)

find_package(Thrust REQUIRED CONFIG)

find_package(Threads REQUIRED)

add_library(adaptive_octree
    src/octree/octree.cu
    src/octree/octree_print.cu
    src/common/tree_view.cu
    src/kdtree3d/kdtree3d.cu
    src/kdtree3d/kdtree3d_print.cu
)

add_library(adaptive_octree::adaptive_octree ALIAS adaptive_octree)

target_compile_features(adaptive_octree PUBLIC cxx_std_20)

target_compile_options(adaptive_octree
    PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-O3>
        $<$<COMPILE_LANGUAGE:CUDA>:-O3>
        $<$<COMPILE_LANGUAGE:CUDA>:-lineinfo>
)

target_include_directories(adaptive_octree
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src/common
)

target_link_libraries(adaptive_octree
    PUBLIC
        Thrust::Thrust
        #jsc
)

if(PROJECT_IS_TOP_LEVEL)
    if(BUILD_TESTING)
        add_subdirectory(tests)
    endif()
endif()

option(ADAPTIVE_OCTREE_BENCH_CSV
    "Write snapshot benchmark output to CSV instead of terminal"
    OFF
)

option(ADAPTIVE_OCTREE_PROFILING
    "Compile in NVTX profiling ranges (adds an nvtx3 dependency)"
    OFF
)

if(ADAPTIVE_OCTREE_PROFILING)
    target_compile_definitions(adaptive_octree PUBLIC ADAPTIVE_OCTREE_PROFILING)
endif()
