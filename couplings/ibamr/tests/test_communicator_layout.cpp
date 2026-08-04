#include "CommunicatorLayout.h"

#include <mpi.h>

#include <stdexcept>

int main(int argc, char** argv)
{
  int provided = MPI_THREAD_SINGLE;
  MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided);
  if (provided < MPI_THREAD_SERIALIZED) MPI_Abort(MPI_COMM_WORLD, 92);

  bool rejected_null = false;
  try {
    ibamr_smarties::CommunicatorLayout invalid(MPI_COMM_NULL);
  }
  catch (const std::invalid_argument&) {
    rejected_null = true;
  }
  if (!rejected_null) MPI_Abort(MPI_COMM_WORLD, 1);

  int world_rank = -1;
  MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);

  MPI_Comm local_comm = MPI_COMM_NULL;
  MPI_Comm_split(MPI_COMM_WORLD, world_rank % 2, world_rank, &local_comm);
  ibamr_smarties::CommunicatorLayout layout(local_comm);

  const bool valid = layout.valid() && layout.size() == 1 && layout.rank() == 0;
  MPI_Comm_free(&local_comm);
  if (!valid) MPI_Abort(MPI_COMM_WORLD, 2);

  MPI_Finalize();
  return 0;
}
