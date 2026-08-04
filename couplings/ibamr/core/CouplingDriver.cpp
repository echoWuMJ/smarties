#include "CouplingDriver.h"

namespace ibamr_smarties
{

CouplingDriver::CouplingDriver(int& argc, char**& argv)
  : mpi_(argc, argv), argc_(argc), argv_(argv)
{
}

int CouplingDriver::run(const EnvironmentCallback& callback)
{
  smarties::Engine engine(mpi_.world(), argc_, argv_);
  if (engine.parse()) return 2;

  engine.run(callback);

  int finalized = 0;
  MPI_Finalized(&finalized);
  if (finalized) return 93;
  return 0;
}

} // namespace ibamr_smarties
