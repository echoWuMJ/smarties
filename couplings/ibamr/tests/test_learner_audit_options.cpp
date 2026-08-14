#include "smarties/Settings/ExecutionInfo.h"

#include <mpi.h>

#include <algorithm>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#ifndef SMARTIES_LEARNER_APPROXIMATOR_SOURCE
#error "SMARTIES_LEARNER_APPROXIMATOR_SOURCE must name Learner_approximator.cpp"
#endif

namespace
{
int parseArguments(const std::vector<std::string>& arguments,
                   std::string* const auditDirectory)
{
  std::vector<std::vector<char>> storage;
  storage.reserve(arguments.size());
  for (const std::string& argument : arguments)
  {
    storage.emplace_back(argument.begin(), argument.end());
    storage.back().push_back('\0');
  }

  std::vector<char*> argv;
  argv.reserve(storage.size() + 1);
  for (auto& argument : storage) argv.push_back(argument.data());
  argv.push_back(nullptr);

  int argc = static_cast<int>(arguments.size());
  smarties::ExecutionInfo execution(MPI_COMM_WORLD, argc, argv.data());
  const int status = execution.parse();
  if (auditDirectory != nullptr) *auditDirectory = execution.learnerAuditDir;
  return status;
}

std::string compactSource(const std::string& source)
{
  std::string compact;
  compact.reserve(source.size());
  for (const char c : source)
    if (c != ' ' && c != '\t' && c != '\r' && c != '\n') compact.push_back(c);
  return compact;
}

bool disabledGuardPrecedes(const std::string& source,
                           const std::string& function,
                           const std::vector<std::string>& effects)
{
  const std::string signature =
    "voidLearner_approximator::" + function + "(";
  const std::size_t begin = source.find(signature);
  if (begin == std::string::npos) return false;

  const std::size_t guard = source.find(
    "if(distrib.learnerAuditDir==\"none\")return;", begin);
  if (guard == std::string::npos) return false;

  for (const std::string& effect : effects)
  {
    const std::size_t position = source.find(effect, begin);
    if (position == std::string::npos || guard >= position) return false;
  }
  return true;
}
} // namespace

int main(int argc, char** argv)
{
  int provided = MPI_THREAD_SINGLE;
  MPI_Init_thread(&argc, &argv, MPI_THREAD_MULTIPLE, &provided);
  if (provided < MPI_THREAD_MULTIPLE) MPI_Abort(MPI_COMM_WORLD, 90);

  int result = 0;
  {
    std::string directory;
    if (parseArguments({ "learner-audit-options" }, &directory) != 0 ||
        directory != "none")
      result = 1;

    if (result == 0 &&
        (parseArguments({ "learner-audit-options", "--learnerAuditDir",
                          "/tmp/smarties-learner-audit" }, &directory) != 0 ||
         directory != "/tmp/smarties-learner-audit"))
      result = 2;

    if (result == 0 &&
        parseArguments({ "learner-audit-options", "--learnerAuditDir",
                         "relative/audit" }, nullptr) == 0)
      result = 3;

    if (result == 0 &&
        parseArguments({ "learner-audit-options", "--learnerAuditDir", "" },
                       nullptr) == 0)
      result = 4;

    std::ifstream input(SMARTIES_LEARNER_APPROXIMATOR_SOURCE);
    const std::string source((std::istreambuf_iterator<char>(input)),
                             std::istreambuf_iterator<char>());
    const std::string compact = compactSource(source);
    if (result == 0 && !input.good() && source.empty()) result = 5;
    if (result == 0 &&
        !disabledGuardPrecedes(compact, "emitNetworkAudit",
                               { "auditParameters(" }))
      result = 6;
    if (result == 0 &&
        !disabledGuardPrecedes(compact, "saveAuditCheckpoint",
                               { "createDirectoriesAbsolute(" }))
      result = 7;
  }

  MPI_Finalize();
  return result;
}
