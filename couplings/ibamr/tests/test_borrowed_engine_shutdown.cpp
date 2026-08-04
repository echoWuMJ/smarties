#include <smarties.h>

#include <mpi.h>

int main(int argc, char** argv)
{
  int provided = MPI_THREAD_SINGLE;
  MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided);
  if (provided < MPI_THREAD_SERIALIZED) MPI_Abort(MPI_COMM_WORLD, 90);

  {
    smarties::Engine engine(MPI_COMM_WORLD, argc, argv);
  }

  int finalized = 0;
  MPI_Finalized(&finalized);
  if (finalized) return 1;

  MPI_Finalize();
  return 0;
}
