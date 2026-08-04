#include "CommunicatorLayout.h"

#include <stdexcept>

namespace ibamr_smarties
{

CommunicatorLayout::CommunicatorLayout(MPI_Comm communicator) :
  communicator_(communicator)
{
  if (communicator_ == MPI_COMM_NULL) {
    throw std::invalid_argument("CommunicatorLayout requires a valid communicator");
  }

  if (MPI_Comm_rank(communicator_, &rank_) != MPI_SUCCESS ||
      MPI_Comm_size(communicator_, &size_) != MPI_SUCCESS) {
    throw std::runtime_error("CommunicatorLayout could not query communicator");
  }
}

} // namespace ibamr_smarties
