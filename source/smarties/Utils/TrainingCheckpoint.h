#ifndef smarties_TrainingCheckpoint_h
#define smarties_TrainingCheckpoint_h
#include "../Settings/Definitions.h"
#include <atomic>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <locale>
#include <sstream>
#include <stdexcept>
#include <type_traits>

namespace smarties {
// Paired checkpoints are native-build artifacts, not the legacy float .raw
// policy export. Every owner visits its state explicitly, without object padding.
class TrainingCheckpoint {
  std::fstream file;
  std::string path;
public:
  const bool reading;
  TrainingCheckpoint(const std::string& p, bool read, const std::string& kind)
    : path(p), reading(read) {
    file.open(p, std::ios::binary | (read ? std::ios::in : std::ios::out|std::ios::trunc));
    require(bool(file), "cannot open checkpoint");
    expect(std::string("SMARTIES_PAIRED_NATIVE")); expect(std::uint32_t(1));
    expect(std::uint32_t(0x01020304)); expect(std::uint32_t(sizeof(Real)));
    expect(std::uint32_t(sizeof(nnReal))); expect(std::uint32_t(sizeof(long double)));
    expect(std::uint32_t(sizeof(Fval))); expect(std::uint32_t(sizeof(Uint)));
    expect(std::uint32_t(sizeof(long))); expect(std::uint32_t(sizeof(bool)));
    expect(kind);
  }
  void require(bool good, const char* why) const {
    if(!good) throw std::runtime_error(path + ": " + why);
  }
  void bytes(void* p, std::size_t n) {
    if(reading) file.read(static_cast<char*>(p), n);
    else file.write(static_cast<const char*>(p), n);
    require(bool(file), "truncated read or failed write");
  }
  template<class T> typename std::enable_if<std::is_arithmetic<T>::value || std::is_enum<T>::value>::type
  value(T& x) { bytes(&x,sizeof(x)); }
  template<class T> void value(std::atomic<T>& x) {
    T copy=x.load(); value(copy); if(reading) x.store(copy);
  }
  template<class T> void value(std::vector<T>& x) {
    std::uint64_t size=x.size(); value(size);
    require(size <= 100000000, "invalid vector length");
    if(reading) x.resize(size);
    for(auto& item:x) value(item);
  }
  void value(std::vector<bool>& x) {
    std::uint64_t size=x.size(); value(size);
    require(size<=100000000,"invalid boolean vector length");
    if(reading) x.resize(size);
    for(std::size_t i=0;i<size;++i) {
      std::uint8_t item=x[i]?1:0; value(item);
      require(item<=1,"invalid boolean"); if(reading) x[i]=item!=0;
    }
  }
  void value(std::string& x) {
    std::uint64_t size=x.size(); value(size);
    require(size<=1024*1024, "invalid string length");
    if(reading) x.resize(size);
    if(size) bytes(&x[0],size);
  }
  template<class T> void expect(const T& expected) {
    T actual=expected; value(actual); require(actual==expected,"incompatible checkpoint");
  }
  template<class T> void random(T& x) {
    std::string state;
    if(!reading) { std::ostringstream out; out.imbue(std::locale::classic());
      out << std::setprecision(std::numeric_limits<long double>::max_digits10) << x;
      require(bool(out),"cannot serialize random state"); state=out.str(); }
    value(state);
    if(reading) { std::istringstream in(state); in.imbue(std::locale::classic());
      in >> x; require(!in.fail(),"invalid random state");
      in >> std::ws; require(in.eof(),"trailing random state"); }
  }
  template<class T, class... Rest> void operator()(T& x, Rest&... rest) {
    value(x); (*this)(rest...);
  }
  void operator()() {}
  void finish() {
    if(reading) require(file.peek()==std::char_traits<char>::eof(),"trailing checkpoint data");
    else { file.flush(); require(bool(file),"checkpoint flush failed"); }
    file.close(); require(!file.fail(),"checkpoint close failed");
  }
};
}
#endif
