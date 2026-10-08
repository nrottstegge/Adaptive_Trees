include(FetchContent)
FetchContent_Declare(Catch2 GIT_REPOSITORY https://github.com/catchorg/Catch2.git GIT_TAG v3.7.1)
FetchContent_MakeAvailable(Catch2)

add_executable(tree_test tree_test.cu)
add_executable(tree_example tree_example.cu)
add_executable(bench_snapshots bench_snapshots.cu)

foreach(target tree_test tree_example bench_snapshots)
    target_link_libraries(${target} PRIVATE adaptive_octree::adaptive_octree)
    target_compile_options(${target} PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:-lineinfo>)
endforeach()

target_link_libraries(tree_test PRIVATE Catch2::Catch2WithMain)
target_link_libraries(bench_snapshots PRIVATE Threads::Threads)

add_test(NAME tree_test COMMAND tree_test)
add_test(NAME tree_example COMMAND tree_example)

if(ADAPTIVE_OCTREE_BENCH_CSV)
    target_compile_definitions(bench_snapshots PRIVATE ADAPTIVE_OCTREE_BENCH_CSV)
endif()
