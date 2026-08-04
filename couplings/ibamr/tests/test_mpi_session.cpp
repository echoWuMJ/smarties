#include "MpiSession.h"

#include <mpi.h>

#include <type_traits>

static_assert(!std::is_copy_constructible<ibamr_smarties::MpiSession>::value,
              "MpiSession must not be copy constructible");
static_assert(!std::is_move_constructible<ibamr_smarties::MpiSession>::value,
              "MpiSession must not be move constructible");

int main(int argc, char** argv)
{
  int initialized = 0;
  MPI_Initialized(&initialized);
  if (initialized) return 1;

  {
    ibamr_smarties::MpiSession session(argc, argv);
    MPI_Initialized(&initialized);
    if (!initialized) return 2;

    int finalized = 0;
    MPI_Finalized(&finalized);
    if (finalized) return 3;
    if (session.world() != MPI_COMM_WORLD) return 4;
  }

  int finalized = 0;
  MPI_Finalized(&finalized);
  return finalized ? 0 : 5;
}
