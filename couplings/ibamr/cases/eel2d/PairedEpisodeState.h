#pragma once
#include "EelControlTask.h"
#include "EelVelocityProbes.h"
#include <cmath>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>

namespace ibamr_smarties { namespace eel2d {
inline bool parseUnsignedField(std::istream& in, unsigned& value) {
  std::string token;
  if (!(in>>token) || token.empty() || token.front()=='-') return false;
  try {
    std::size_t used=0;
    const auto parsed=std::stoull(token,&used);
    if (used!=token.size() || parsed>std::numeric_limits<unsigned>::max()) return false;
    value=static_cast<unsigned>(parsed);
    return true;
  } catch (const std::exception&) {
    return false;
  }
}
// A: feedback consumed by learner, action selected but not yet sent to CFD.
// N: no live CFD; episode is the number to start next, not one to replay.
struct ProxyRestart {
  unsigned episode=0, sequence=0;
  char kind='N';
  double action=0;
};
inline ProxyRestart parseProxyRestart(const std::string& text) {
  std::istringstream in(text); unsigned version=0; ProxyRestart state; std::string extra;
  if (!parseUnsignedField(in,version) || !parseUnsignedField(in,state.episode) ||
      !parseUnsignedField(in,state.sequence) || !(in>>state.kind>>state.action) ||
      version!=1 || !state.episode || !std::isfinite(state.action) ||
      state.action < -1 || state.action > 1 ||
      (state.kind!='A' && state.kind!='N') ||
      (state.kind=='A' && !state.sequence) || (state.kind=='N' && state.sequence) ||
      (in>>extra)) throw std::runtime_error("invalid paired proxy state");
  return state;
}
inline std::string serializeProxyRestart(const ProxyRestart& state) {
  std::ostringstream out;
  out<<std::setprecision(17)<<1<<' '<<state.episode<<' '<<state.sequence<<' '<<state.kind<<' '<<state.action;
  parseProxyRestart(out.str()); return out.str();
}
struct CfdRestart {
  double height=0;
  unsigned decisions=0, sequence=0;
  EelControlHistory control{};
  EelVelocityProbeSample probes{};
};
inline CfdRestart parseCfdRestart(const std::string& text) {
  std::istringstream in(text); unsigned version=0; CfdRestart state; std::string extra;
  if (!parseUnsignedField(in,version) || !(in>>state.height) ||
      !parseUnsignedField(in,state.decisions) || !parseUnsignedField(in,state.sequence) ||
      !(in>>state.control.applied_ratio) ||
      !parseUnsignedField(in,state.control.clipped_action_count) ||
      version!=1 || !std::isfinite(state.height) || state.height<=0 ||
      !state.sequence || state.sequence-1!=state.decisions ||
      !std::isfinite(state.control.applied_ratio) || state.control.applied_ratio<=0)
    throw std::runtime_error("invalid paired CFD state");
  for (auto* array:{&state.probes.positions,&state.probes.velocities})
    for (auto& point:*array) for (auto& x:point)
      if (!(in>>x) || !std::isfinite(x)) throw std::runtime_error("invalid saved probes");
  if (in>>extra) throw std::runtime_error("extra paired CFD state fields");
  return state;
}
inline std::string serializeCfdRestart(const CfdRestart& state) {
  std::ostringstream out;
  out<<std::setprecision(17)<<1<<' '<<state.height<<' '<<state.decisions<<' '<<state.sequence
     <<' '<<state.control.applied_ratio<<' '<<state.control.clipped_action_count;
  for (const auto* array:{&state.probes.positions,&state.probes.velocities})
    for (const auto& point:*array) for (const auto x:point) out<<' '<<x;
  parseCfdRestart(out.str()); return out.str();
}
} }
