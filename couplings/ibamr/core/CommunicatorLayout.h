#ifndef IBAMR_SMARTIES_COMMUNICATOR_LAYOUT_H
#define IBAMR_SMARTIES_COMMUNICATOR_LAYOUT_H

#include <mpi.h>

namespace ibamr_smarties
{

class CommunicatorLayout
{
public:
  explicit CommunicatorLayout(MPI_Comm communicator);

  int rank() const { return rank_; }
  int size() const { return size_; }
  bool valid() const { return communicator_ != MPI_COMM_NULL && rank_ >= 0 && size_ > 0; }

private:
  MPI_Comm communicator_ = MPI_COMM_NULL;
  int rank_ = -1;
  int size_ = 0;
};

} // namespace ibamr_smarties

#endif
