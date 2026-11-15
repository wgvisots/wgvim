#include <map>
#include <string>
namespace demo {
enum class Color : int { Red = 1, Green = 22, Blue = 333 };
struct Point { int x; int y; };
constexpr Point pts[] = {{1, 2}, {100, 200}, {3, 40}};
class Widget : public Base<int, double> {
public:
  Widget() = default;
  int size() const { return n_; }
  void set_size(int n) { n_ = n; }
  const std::string& name() const { return name_; }
private:
  std::map<int, std::string> lookup_{}; // id -> name
  int n_{0}; // count
  std::string name_{"default"}; // the name
  const char* raw_ = R"(a, b; {c})";
};
int compute(int a, int b) {
  int x = a + b;
  int total_count = foo(a, b);
  x += 3;
  total_count <<= 2;
  if (x < total_count) {
    return (x);
  }
  switch (x) {
  case 1: return 10;
  case 22: return 200;
  default: break;
  }
  auto f = [](int a) { return a; };
  auto g = [](int bb) { return bb * 2; };
  /* block
     comment */
  std::cout << "a, b" << x << '\n';
  std::cout << "ccc;d" << total_count << '\n';
  call(a, "x;y");
  call(bbb, "z");
  return x;
}
#define SQUARE(x) ((x) * (x))
#define CUBE(x)   ((x) * (x) * (x))
// clang-format off
int   keep  =   1;
int keep2 = 22;
// clang-format on
} // namespace demo
