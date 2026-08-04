#include "MpiSession.h"

#include <stdexcept>

namespace ibamr_smarties
{

MpiSession::MpiSession(int& argc, char**& argv)
{
  int initialized = 0;
  MPI_Initialized(&initialized);
  if (initialized) {
    throw std::runtime_error(
      "MpiSession requires ownership before MPI initialization");
  }

  MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided_);
  if (provided_ < MPI_THREAD_SERIALIZED) MPI_Abort(MPI_COMM_WORLD, 91);
}

MpiSession::~MpiSession()
{
  int finalized = 0;
  MPI_Finalized(&finalized);
  if (!finalized) MPI_Finalize();
}

} // namespace ibamr_smarties
