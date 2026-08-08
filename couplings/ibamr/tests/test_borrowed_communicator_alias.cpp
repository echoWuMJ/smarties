#include "smarties/Settings/ExecutionInfo.h"

#include <mpi.h>

int main(int argc, char** argv)
{
  int provided = MPI_THREAD_SINGLE;
  MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided);
  if (provided < MPI_THREAD_SERIALIZED) MPI_Abort(MPI_COMM_WORLD, 90);

  MPI_Comm borrowed = MPI_COMM_NULL;
  MPI_Comm_dup(MPI_COMM_WORLD, &borrowed);
  MPI_Comm_set_errhandler(borrowed, MPI_ERRORS_RETURN);

  {
    smarties::ExecutionInfo execution(borrowed, argc, argv);
    execution.forkableApplication = true;
    execution.nMasters = 1;
    execution.nEnvironments = 1;
    execution.figureOutWorkersPattern();
  }

  int rank = -1;
  const int status = MPI_Comm_rank(borrowed, &rank);
  if (status != MPI_SUCCESS || rank != 0) MPI_Abort(MPI_COMM_WORLD, 91);

  MPI_Comm_free(&borrowed);
  MPI_Finalize();
  return 0;
}
