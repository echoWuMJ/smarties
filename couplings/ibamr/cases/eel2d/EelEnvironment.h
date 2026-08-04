#ifndef IBAMR_SMARTIES_EEL_ENVIRONMENT_H
#define IBAMR_SMARTIES_EEL_ENVIRONMENT_H

#include <mpi.h>

#include <memory>
#include <string>

namespace ibamr_smarties
{
namespace eel2d
{

class EelEnvironment
{
public:
  EelEnvironment();
  ~EelEnvironment();

  EelEnvironment(const EelEnvironment&) = delete;
  EelEnvironment& operator=(const EelEnvironment&) = delete;

  void initialize(MPI_Comm environment_comm, const std::string& input_file);
  void advanceOneStep();
  bool stepsRemaining() const;
  void shutdown();

private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace eel2d
} // namespace ibamr_smarties

#endif
