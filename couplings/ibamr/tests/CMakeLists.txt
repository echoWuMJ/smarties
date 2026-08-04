add_executable(borrowed_engine_shutdown test_borrowed_engine_shutdown.cpp)
target_link_libraries(borrowed_engine_shutdown PRIVATE libsmarties MPI::MPI_CXX)

add_executable(owned_engine_shutdown test_owned_engine_shutdown.cpp)
target_link_libraries(owned_engine_shutdown PRIVATE libsmarties MPI::MPI_CXX)

add_test(
  NAME borrowed_engine_shutdown
  COMMAND ${MPIEXEC_EXECUTABLE} ${MPIEXEC_NUMPROC_FLAG} 1
          ${MPIEXEC_PREFLAGS} $<TARGET_FILE:borrowed_engine_shutdown>
          ${MPIEXEC_POSTFLAGS})

add_test(NAME owned_engine_shutdown COMMAND owned_engine_shutdown)
