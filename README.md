# agentic-film-studio

> Agent-based AI short film / drama automation pipeline — modular, auditable, extensible.

![License](https://img.shields.io/badge/License-Apache--2.0-blue.svg)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

---

## Overview

**agentic-film-studio** is an open-source, multi-agent pipeline for generating AI short films and drama content. It decomposes the filmmaking workflow into five specialized agents, each responsible for a distinct stage of production — from script ideation through final composite delivery.

The system is designed for **modularity, auditability, and extensibility**. Each agent operates independently with well-defined inputs and outputs, enabling teams to swap, upgrade, or extend individual components without disrupting the whole pipeline.

---

## The Five Agents

### 🎭 Agent A — Script Engine
Transforms creative concepts into production-ready scripts with structured beat sheets, three-act pacing, and locked visual style references.
- **Input**: Creative brief, genre, tone, character concepts
- **Output**: Engineering-grade script with scene-by-scene breakdown, character arcs, and visual style specifications
- **Key capabilities**: Beat extraction, dialogue structuring, visual consistency enforcement

### 🎨 Agent B — Storyboard & Asset Engine
Generates all pre-production visual assets: character reference cards (9 dimensions), prop cards (6 dimensions), scene cards (7 dimensions including lighting tables & camera SVG diagrams), storyboard panels (5 dimensions + 8-element prompts), and camera movement reference videos.
- **Input**: Script from Agent A
- **Output**: Complete asset pack ready for rendering
- **Key capabilities**: Multi-dimensional card generation, camera reference, scene composition, prompt engineering

### 🎬 Agent C — Render Engine
Orchestrates multi-modal video generation across supported APIs (Seedance 2.0, Tongyi Wanxiang, Jimeng, Kling) with an L0→L1→L2 degradation chain for graceful fallback.
- **Input**: Asset pack from Agent B
- **Output**: Rendered video segments per scene/segment
- **Key capabilities**: Multi-provider dispatch, cost-budget tracking, segment-level idempotency, graceful degradation

### 🔍 Agent D — Audit Engine
Serves as a quality gatekeeper with an S+ delivery gate system: pre-render audit (mandatory before Agent C starts), sample audit (cost-saving gate before full production), and final delivery audit. Supports iterative re-review (max 3 rounds).
- **Input**: Any agent's output at audit gates
- **Output**: Pass/fail verdict with actionable feedback
- **Key capabilities**: Multi-dimensional scoring, platform compliance pre-check, iterative feedback loop

### ✂️ Agent E — Post-Production Engine
Handles final assembly: ffmpeg-based compositing, Doubao TTS fallback dubbing, subtitle generation (SRT-locked), and final delivery packaging.
- **Input**: Rendered segments from Agent C
- **Output**: Final composite video with audio and subtitles
- **Key capabilities**: Automated compositing, TTS dubbing, subtitle synchronization, cost accounting

---

## Architecture Highlights

- **🔧 Modular 5-Agent Design** — Each agent is independently testable, replaceable, and extensible. Orchestration discipline ensures clean handoffs.
- **📚 Creative Knowledge Base** — 24+ domain-specific knowledge YAML files covering cinematography, lighting, pacing, costs, and more, replacing hard-coded rules with curated expertise.
- **🤖 Multi-Model Collaboration** — Integrates with Seedance 2.0 (Doubao ARK), Doubao TTS, Tongyi Wanxiang, Jimeng, Kling, and more, selecting the best model for each task.
- **📊 Built-in Audit & Cost Tracking** — Quality gates at every critical stage; per-segment cost accounting with API-level scanning and deviation alerts.
- **📁 Filesystem as SSOT** — All state is tracked through STATUS.yaml files per project, enabling reliable pipeline resumption and observability without runtime dependency.

---

## Demo

> **cafe-reunion-v2** — A sample AI-generated short film produced end-to-end by agentic-film-studio.

| File | Description |
|------|-------------|
| [`demos/cafe-reunion-v2.mp4`](demos/cafe-reunion-v2.mp4) | Final composite (AI-generated, technical demonstration only) |

**Note**: This demo is provided solely as a technical demonstration of the pipeline's capabilities. All visual and audio content is AI-generated.

---

## Getting Started

### Prerequisites

- Python 3.10+
- ffmpeg (for post-production assembly)
- API keys for your chosen model providers

### Installation

```bash
# Clone the repository
git clone https://github.com/zhakleenhoote-lang/agentic-film-studio.git
cd agentic-film-studio

# Set up your environment
python -m venv venv
source venv/bin/activate  # or `venv\Scripts\activate` on Windows

# Configure API credentials
# See docs/configuration.md for provider-specific setup
```

### Quick Start

```bash
# Run the full pipeline with a project brief
# See docs/ for detailed usage
```

---

## Contributing

We welcome contributions! Here's how you can help:

### Issue Templates

- **Bug Report** — Something not working? Open a bug report with reproduction steps.
- **Feature Request** — Have an idea for improvement? Share it with us.
- **Documentation** — Found a gap or error in docs? Let us know.

### Pull Request Workflow

1. **Fork** the repository
2. **Create a feature branch** (`git checkout -b feat/your-feature`)
3. **Commit your changes** (`git commit -m "feat: description of change"`)
4. **Push to your fork** (`git push origin feat/your-feature`)
5. **Open a Pull Request** against the `main` branch

### Guidelines

- Keep commits focused — one logical change per commit
- Write clear commit messages following [Conventional Commits](https://www.conventionalcommits.org/)
- Add or update tests for any functional changes
- Update documentation for API changes or new features
- Be respectful and constructive in all interactions

### Maintainer

This project is currently maintained by a single maintainer. External contributions are welcome and reviewed regularly.

### Code of Conduct

We are committed to fostering a welcoming, inclusive, and harassment-free community. All participants — contributors, maintainers, and users — are expected to:

- Be respectful and considerate in all communications
- Accept constructive feedback graciously
- Focus on what's best for the community and the project
- Refrain from any form of discrimination, harassment, or personal attacks

---

## Credits & Acknowledgments

### Inspiration

This project was inspired by **Toonflow** by HBAI Ltd ([HBAI-Ltd/Toonflow-app](https://github.com/HBAI-Ltd/Toonflow-app)), also Apache-2.0 licensed. The modular agent-based approach to AI video production builds on concepts pioneered in Toonflow's pipeline architecture.

### Technology Partners

- **[Seedance 2.0](https://www.volcengine.com/)** (Volcengine ARK) — Multi-modal video generation, the primary rendering backend
- **[Doubao TTS](https://www.volcengine.com/)** (Volcengine ARK) — Speech synthesis for fallback dubbing
- **[Tongyi Wanxiang](https://tongyi.aliyun.com/)** (Alibaba Cloud) — Image and video generation
- **[Jimeng](https://jimeng.jd.com/)** — Visual content generation
- **[Kling](https://kling.kuaishou.com/)** — Video generation

### Open Source References

- [seedance-2.0-skill-os](https://github.com/Emily2040/seedance-2.0-skill-os) (Emily2040, MIT) — Open-source reference implementation for Seedance 2.0 integration

---

## License

Copyright 2026 agentic-film-studio contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

See the [LICENSE](LICENSE) file for the full license text.
