#pragma once

#include "gfa_parser.hpp"
#include <array>
#include <cstdint>
#include <utility>

namespace odgi {
namespace algorithms {

struct gfagraph_summary_t {
  uint64_t length_in_bp = 0;
  uint64_t node_count = 0;
  uint64_t edge_count = 0;
  uint64_t path_count = 0;
  uint64_t step_count = 0;
};

gfagraph_summary_t summarize_gfagraph(const GfaGraph& gfa_graph);
std::array<uint64_t, 256> gfagraph_base_content(const GfaGraph& gfa_graph);
std::pair<uint64_t, uint64_t> gfagraph_self_loops(const GfaGraph& gfa_graph);

} // namespace algorithms
} // namespace odgi
