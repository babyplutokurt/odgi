#include "gfagraph_stats.hpp"
#include <unordered_set>

namespace odgi {
namespace algorithms {

gfagraph_summary_t summarize_gfagraph(const GfaGraph& gfa_graph) {
  gfagraph_summary_t summary;

  if (gfa_graph.node_sequences.size() > 1) {
    summary.node_count = gfa_graph.node_sequences.size() - 1;
    for (size_t i = 1; i < gfa_graph.node_sequences.size(); ++i) {
      summary.length_in_bp += gfa_graph.node_sequences[i].size();
    }
  }

  summary.edge_count = gfa_graph.links.from_ids.size();
  summary.path_count = gfa_graph.paths.size() + gfa_graph.walks.size();

  for (const auto& path : gfa_graph.paths) {
    summary.step_count += path.size();
  }
  for (const auto& walk : gfa_graph.walks.walks) {
    summary.step_count += walk.size();
  }

  return summary;
}

std::array<uint64_t, 256> gfagraph_base_content(const GfaGraph& gfa_graph) {
  std::array<uint64_t, 256> chars{};
  for (size_t i = 1; i < gfa_graph.node_sequences.size(); ++i) {
    for (unsigned char c : gfa_graph.node_sequences[i]) {
      ++chars[c];
    }
  }
  return chars;
}

std::pair<uint64_t, uint64_t> gfagraph_self_loops(const GfaGraph& gfa_graph) {
  uint64_t total_self_loops = 0;
  std::unordered_set<uint32_t> unique_self_loop_nodes;
  unique_self_loop_nodes.reserve(gfa_graph.links.from_ids.size());

  for (size_t i = 0; i < gfa_graph.links.from_ids.size(); ++i) {
    if (gfa_graph.links.from_ids[i] == gfa_graph.links.to_ids[i]) {
      ++total_self_loops;
      unique_self_loop_nodes.insert(gfa_graph.links.from_ids[i]);
    }
  }
  return std::make_pair(total_self_loops, unique_self_loop_nodes.size());
}

} // namespace algorithms
} // namespace odgi
