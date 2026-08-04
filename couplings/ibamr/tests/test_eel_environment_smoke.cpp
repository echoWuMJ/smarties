#include "EelEnvironment.h"
#include "MpiSession.h"

#include <mpi.h>

int main(int argc, char** argv)
{
  if (argc != 2) return 64;

  ibamr_smarties::MpiSession mpi(argc, argv);
  ibamr_smarties::eel2d::EelEnvironment environment;
  environment.initialize(mpi.world(), argv[1]);
  if (!environment.stepsRemaining()) return 1;

  environment.advanceOneStep();
  environment.shutdown();

  int finalized = 0;
  MPI_Finalized(&finalized);
  if (finalized) return 3;
  return 0;
}
