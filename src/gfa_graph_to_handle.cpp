#include "gfa_graph_to_handle.hpp"
#include "atomic_queue.h"
#include "progress.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <iostream>
#include <mutex>
#include <sstream>
#include <thread>

namespace odgi {

struct gfa_graph_path_job_t {
  handlegraph::path_handle_t path;
  const std::vector<NodeId>* steps;
  const std::string* name;
  bool is_walk;
};

typedef atomic_queue::AtomicQueue<gfa_graph_path_job_t*, 2 << 10>
    gfa_graph_path_queue_t;

void gfa_graph_to_handle(const GfaGraph &gfa_graph,
                         handlegraph::MutablePathMutableHandleGraph *graph,
                         bool compact_ids, uint64_t n_threads,
                         bool show_progress) {

  n_threads = (n_threads == 0 ? 1 : n_threads);
  std::atomic<bool> failed{false};
  std::mutex error_mutex;
  std::string error_message;

  auto record_error = [&](const std::string& msg) {
    bool expected = false;
    if (failed.compare_exchange_strong(expected, true)) {
      std::lock_guard<std::mutex> lock(error_mutex);
      error_message = msg;
    }
  };

  auto abort_if_failed = [&]() {
    if (failed.load()) {
      std::cerr << error_message << std::endl;
      exit(1);
    }
  };

  // 1. Nodes (S-lines). In GfaGraph, index 0 is placeholder
  if (gfa_graph.node_sequences.size() > 1) {
    std::unique_ptr<algorithms::progress_meter::ProgressMeter> progress_meter;
    if (show_progress) {
      progress_meter =
          std::make_unique<algorithms::progress_meter::ProgressMeter>(
              gfa_graph.node_sequences.size() - 1,
              "[odgi::gfa_graph_to_handle] building nodes:");
    }

    for (size_t i = 1; i < gfa_graph.node_sequences.size(); ++i) {
      uint64_t id = i;
      graph->create_handle(gfa_graph.node_sequences[i], id);
      if (show_progress)
        progress_meter->increment(1);
    }

    if (show_progress)
      progress_meter->finish();
  }

  // 2. Edges (L-lines)
  if (!gfa_graph.links.from_ids.empty()) {
    std::unique_ptr<algorithms::progress_meter::ProgressMeter> progress_meter;
    if (show_progress) {
      progress_meter =
          std::make_unique<algorithms::progress_meter::ProgressMeter>(
              gfa_graph.links.from_ids.size(),
              "[odgi::gfa_graph_to_handle] building edges:");
    }

    for (size_t i = 0; i < gfa_graph.links.from_ids.size(); ++i) {
      uint64_t source_id = gfa_graph.links.from_ids[i];
      uint64_t sink_id = gfa_graph.links.to_ids[i];
      bool from_is_rev = gfa_graph.links.from_orients[i] == '-';
      bool to_is_rev = gfa_graph.links.to_orients[i] == '-';

      if (graph->has_node(source_id) && graph->has_node(sink_id)) {
        handlegraph::handle_t a = graph->get_handle(source_id, from_is_rev);
        handlegraph::handle_t b = graph->get_handle(sink_id, to_is_rev);
        graph->create_edge(a, b);
      } else {
        std::ostringstream oss;
        oss << "[odgi::gfa_graph_to_handle] Error creating edge due to "
               "missing node(s): "
            << source_id << " -> " << sink_id;
        record_error(oss.str());
      }
      if (show_progress)
        progress_meter->increment(1);
    }
    abort_if_failed();
    if (show_progress)
      progress_meter->finish();
  }

  // 3. Paths (P-lines)
  if (!gfa_graph.paths.empty()) {
    std::unique_ptr<algorithms::progress_meter::ProgressMeter> progress_meter;
    if (show_progress) {
      progress_meter =
          std::make_unique<algorithms::progress_meter::ProgressMeter>(
              gfa_graph.paths.size(),
              "[odgi::gfa_graph_to_handle] building paths:");
    }

    gfa_graph_path_queue_t path_queue;
    std::atomic<bool> work_todo{false};
    auto worker = [&](uint64_t tid) {
      (void)tid;
      while (work_todo.load()) {
        gfa_graph_path_job_t* job;
        if (path_queue.try_pop(job)) {
          if (!failed.load()) {
            for (NodeId node_id : *job->steps) {
              uint64_t id = std::abs(node_id);
              bool is_rev = node_id < 0;
              if (graph->has_node(id)) {
                graph->append_step(job->path, graph->get_handle(id, is_rev));
              } else {
                std::ostringstream oss;
                oss << "[odgi::gfa_graph_to_handle] Error: Node " << id
                    << " not found for " << (job->is_walk ? "walk " : "path ")
                    << *job->name;
                record_error(oss.str());
                break;
              }
            }
          }
          if (show_progress)
            progress_meter->increment(1);
          delete job;
        } else {
          std::this_thread::sleep_for(std::chrono::nanoseconds(1));
        }
      }
    };

    std::vector<std::thread> workers;
    workers.reserve(n_threads);
    work_todo.store(true);
    for (uint64_t t = 0; t < n_threads; ++t) {
      workers.emplace_back(worker, t);
    }

    for (size_t i = 0; i < gfa_graph.paths.size(); ++i) {
      handlegraph::path_handle_t p_h = graph->create_path_handle(gfa_graph.path_names[i]);
      auto* job = new gfa_graph_path_job_t{
          p_h, &gfa_graph.paths[i], &gfa_graph.path_names[i], false};
      path_queue.push(job);
    }

    while (!path_queue.was_empty()) {
      if (failed.load()) {
        break;
      }
      std::this_thread::sleep_for(std::chrono::nanoseconds(1));
    }
    work_todo.store(false);
    for (auto& t : workers) {
      t.join();
    }
    abort_if_failed();
    if (show_progress)
      progress_meter->finish();
  }

  // 4. Walks (W-lines) conversion
  if (gfa_graph.walks.size() > 0) {
    std::unique_ptr<algorithms::progress_meter::ProgressMeter> progress_meter;
    if (show_progress) {
      progress_meter =
          std::make_unique<algorithms::progress_meter::ProgressMeter>(
              gfa_graph.walks.size(),
              "[odgi::gfa_graph_to_handle] building walks:");
    }

    std::vector<std::string> walk_names(gfa_graph.walks.size());
    gfa_graph_path_queue_t walk_queue;
    std::atomic<bool> work_todo{false};
    auto worker = [&](uint64_t tid) {
      (void)tid;
      while (work_todo.load()) {
        gfa_graph_path_job_t* job;
        if (walk_queue.try_pop(job)) {
          if (!failed.load()) {
            for (NodeId node_id : *job->steps) {
              uint64_t id = std::abs(node_id);
              bool is_rev = node_id < 0;
              if (graph->has_node(id)) {
                graph->append_step(job->path, graph->get_handle(id, is_rev));
              } else {
                std::ostringstream oss;
                oss << "[odgi::gfa_graph_to_handle] Error: Node " << id
                    << " not found for " << (job->is_walk ? "walk " : "path ")
                    << *job->name;
                record_error(oss.str());
                break;
              }
            }
          }
          if (show_progress)
            progress_meter->increment(1);
          delete job;
        } else {
          std::this_thread::sleep_for(std::chrono::nanoseconds(1));
        }
      }
    };

    std::vector<std::thread> workers;
    workers.reserve(n_threads);
    work_todo.store(true);
    for (uint64_t t = 0; t < n_threads; ++t) {
      workers.emplace_back(worker, t);
    }

    for (size_t i = 0; i < gfa_graph.walks.size(); ++i) {
      std::string walk_name = gfa_graph.walks.sample_ids[i] + "#" +
                              std::to_string(gfa_graph.walks.hap_indices[i]) +
                              "#" + gfa_graph.walks.seq_ids[i];

      // If there's sequence start/end, add it to the name optionally depending
      // on odgi conventions, but for now we append it unless it's just the
      // default.
      if (gfa_graph.walks.seq_starts.size() > i &&
          gfa_graph.walks.seq_ends.size() > i &&
          (gfa_graph.walks.seq_starts[i] != -1 ||
           gfa_graph.walks.seq_ends[i] != -1)) {
        walk_name += ":" + std::to_string(gfa_graph.walks.seq_starts[i]) + "-" +
                     std::to_string(gfa_graph.walks.seq_ends[i]);
      }
      walk_names[i] = std::move(walk_name);
      handlegraph::path_handle_t p_h = graph->create_path_handle(walk_names[i]);
      auto* job = new gfa_graph_path_job_t{
          p_h, &gfa_graph.walks.walks[i], &walk_names[i], true};
      walk_queue.push(job);
    }

    while (!walk_queue.was_empty()) {
      if (failed.load()) {
        break;
      }
      std::this_thread::sleep_for(std::chrono::nanoseconds(1));
    }
    work_todo.store(false);
    for (auto& t : workers) {
      t.join();
    }
    abort_if_failed();
    if (show_progress)
      progress_meter->finish();
  }

  if (compact_ids) {
    graph->optimize();
  }
}

} // namespace odgi
