#include "smarties/Core/Launcher.h"

#include <mpi.h>

namespace
{
class TestLauncher : public smarties::Launcher
{
public:
  explicit TestLauncher(smarties::ExecutionInfo& execution)
    : smarties::Launcher(nullptr, execution)
  {
  }

  const std::vector<std::string>& files() const { return argsFiles; }
  const std::vector<smarties::Uint>& limits() const
  {
    return argFilesStepsLimits;
  }
};
} // namespace

int main(int argc, char** argv)
{
  int provided = MPI_THREAD_SINGLE;
  MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided);
  if (provided < MPI_THREAD_SERIALIZED) MPI_Abort(MPI_COMM_WORLD, 90);

  int result = 0;
  {
    smarties::ExecutionInfo execution(MPI_COMM_WORLD, argc, argv);
    execution.randSeed = 1;
    execution.appSettings =
      "app-coarse.args,app-medium.args,app-fine.args";
    execution.nStepPappSett = "1,1,0";
    execution.initialze();

    TestLauncher launcher(execution);
    if (launcher.files().size() != 3) result = 1;
    if (launcher.limits().size() != 4) result = 2;
    if (launcher.limits()[0] != 0 || launcher.limits()[1] != 1 ||
        launcher.limits()[2] != 2) result = 3;
  }

  MPI_Finalize();
  return result;
}
