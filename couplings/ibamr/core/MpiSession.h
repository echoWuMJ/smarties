#ifndef IBAMR_SMARTIES_MPI_SESSION_H
#define IBAMR_SMARTIES_MPI_SESSION_H

#include <mpi.h>

namespace ibamr_smarties
{

class MpiSession
{
public:
  MpiSession(int& argc, char**& argv);
  ~MpiSession();

  MpiSession(const MpiSession&) = delete;
  MpiSession& operator=(const MpiSession&) = delete;
  MpiSession(MpiSession&&) = delete;
  MpiSession& operator=(MpiSession&&) = delete;

  MPI_Comm world() const { return MPI_COMM_WORLD; }

private:
  int provided_ = MPI_THREAD_SINGLE;
};

} // namespace ibamr_smarties

#endif
