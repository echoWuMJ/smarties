#include <smarties.h>

#include <mpi.h>

int main(int argc, char** argv)
{
  {
    smarties::Engine engine(argc, argv);
  }

  int finalized = 0;
  MPI_Finalized(&finalized);
  return finalized ? 0 : 1;
}
