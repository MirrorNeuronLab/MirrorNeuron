#!/usr/bin/env python3
import json
import os
from pathlib import Path


def load_input() -> dict:
    return json.loads(Path(os.environ["MIRROR_NEURON_INPUT_FILE"]).read_text())


def parse_simulation(message: dict) -> dict:
    return json.loads(message["sandbox"]["stdout"])


def build_html(simulation: dict) -> str:
    payload = {"simulation": simulation}

    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MirrorNeuron Shared MPE Crowd</title>
  <style>
    :root {
      --bg: #ede8de;
      --surface: rgba(255, 250, 244, 0.92);
      --ink: #171411;
      --muted: #6f665d;
      --line: rgba(74, 59, 41, 0.14);
      --good: #1d8f5b;
      --good-soft: rgba(29, 143, 91, 0.14);
      --bad: #bf4d28;
      --bad-soft: rgba(191, 77, 40, 0.14);
      --obstacle: #5166d6;
      --obstacle-soft: rgba(81, 102, 214, 0.14);
      --accent: #0f766e;
      --shadow: 0 22px 48px rgba(48, 38, 25, 0.12);
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      font-family: "Avenir Next", "Segoe UI", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, rgba(29, 143, 91, 0.14), transparent 34rem),
        radial-gradient(circle at bottom right, rgba(81, 102, 214, 0.14), transparent 28rem),
        linear-gradient(180deg, #f8f5ef 0%, var(--bg) 100%);
    }

    .page {
      max-width: 1260px;
      margin: 0 auto;
      padding: 28px 18px 40px;
    }

    .hero {
      margin-bottom: 22px;
      display: grid;
      gap: 10px;
    }

    .eyebrow {
      font-size: 12px;
      letter-spacing: 0.18em;
      text-transform: uppercase;
      color: var(--accent);
      font-weight: 800;
    }

    h1 {
      margin: 0;
      font-size: clamp(34px, 6vw, 68px);
      line-height: 0.94;
      max-width: 12ch;
    }

    .hero p {
      margin: 0;
      max-width: 72ch;
      color: var(--muted);
      line-height: 1.6;
      font-size: 17px;
    }

    .layout {
      display: grid;
      grid-template-columns: minmax(320px, 1.45fr) minmax(300px, 0.95fr);
      gap: 18px;
    }

    .panel {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 24px;
      box-shadow: var(--shadow);
      overflow: hidden;
    }

    .panel-inner {
      padding: 18px;
    }

    .controls {
      display: grid;
      gap: 12px;
      margin-bottom: 14px;
    }

    .controls-row {
      display: flex;
      gap: 10px;
      align-items: center;
      flex-wrap: wrap;
    }

    button {
      border: 0;
      border-radius: 999px;
      padding: 10px 14px;
      font: inherit;
      font-weight: 700;
      color: white;
      background: var(--accent);
      cursor: pointer;
    }

    button.secondary {
      color: var(--accent);
      background: rgba(15, 118, 110, 0.12);
    }

    label {
      font-size: 12px;
      letter-spacing: 0.14em;
      text-transform: uppercase;
      color: var(--muted);
      font-weight: 700;
    }

    input[type="range"] {
      width: 100%;
    }

    #cycle-label {
      font-size: 14px;
      color: var(--muted);
    }

    #stage {
      width: 100%;
      aspect-ratio: 1 / 1;
      border-radius: 20px;
      border: 1px solid var(--line);
      background:
        linear-gradient(180deg, rgba(255,255,255,0.55), rgba(244,239,232,0.88)),
        radial-gradient(circle at center, rgba(255,255,255,0.45), rgba(237,232,222,0.80));
      overflow: hidden;
    }

    svg {
      display: block;
      width: 100%;
      height: 100%;
    }

    .cards {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
      margin-top: 14px;
    }

    .card {
      border-radius: 18px;
      border: 1px solid var(--line);
      padding: 14px;
      background: rgba(255, 255, 255, 0.7);
    }

    .card strong {
      display: block;
      margin-top: 8px;
      font-size: 27px;
      line-height: 1;
    }

    .section-title {
      margin: 0 0 10px;
      font-size: 13px;
      letter-spacing: 0.14em;
      text-transform: uppercase;
      color: var(--muted);
    }

    .stack {
      display: grid;
      gap: 12px;
    }

    .copy-box {
      padding: 15px;
      border-radius: 18px;
      border: 1px solid var(--line);
      background: rgba(255, 255, 255, 0.72);
      line-height: 1.55;
      color: var(--ink);
    }

    .team-grid {
      display: grid;
      gap: 10px;
    }

    .team-row {
      border-radius: 18px;
      border: 1px solid var(--line);
      padding: 14px;
      background: rgba(255, 255, 255, 0.72);
    }

    .team-row.good {
      box-shadow: inset 0 0 0 1px var(--good-soft);
    }

    .team-row.adversary {
      box-shadow: inset 0 0 0 1px var(--bad-soft);
    }

    .metric {
      display: flex;
      justify-content: space-between;
      gap: 10px;
      color: var(--muted);
      font-size: 14px;
      margin-top: 6px;
    }

    .timeline {
      width: 100%;
      height: 120px;
      border-radius: 18px;
      border: 1px solid var(--line);
      background: rgba(255, 255, 255, 0.7);
      padding: 10px;
    }

    .legend {
      display: flex;
      flex-wrap: wrap;
      gap: 14px;
      color: var(--muted);
      font-size: 13px;
      margin-top: 12px;
    }

    .legend span {
      display: inline-flex;
      align-items: center;
      gap: 8px;
    }

    .dot {
      display: inline-block;
      width: 10px;
      height: 10px;
      border-radius: 999px;
    }

    .dot.good {
      background: var(--good);
    }

    .dot.bad {
      background: var(--bad);
    }

    .dot.obstacle {
      background: var(--obstacle);
    }

    @media (max-width: 980px) {
      .layout {
        grid-template-columns: 1fr;
      }
    }
  </style>
</head>
<body>
  <div class="page">
    <section class="hero">
      <div class="eyebrow">MirrorNeuron + PettingZoo MPE</div>
      <h1>Shared Crowd Push Arena</h1>
      <p>
        This run keeps every agent inside one shared MPE world. There is no best-rollout picker here:
        the whole point is to watch one crowded environment evolve as good agents flee, adversaries chase,
        and collisions stack up around obstacles.
      </p>
    </section>

    <section class="layout">
      <div class="panel">
        <div class="panel-inner">
          <div class="controls">
            <div class="controls-row">
              <button id="play-toggle">Play</button>
              <button id="restart-button" class="secondary">Restart</button>
              <div id="cycle-label">Cycle 0</div>
            </div>
            <div>
              <label for="cycle-range">Cycle</label>
              <input id="cycle-range" type="range" min="0" max="0" value="0">
            </div>
          </div>

          <div id="stage"></div>

          <div class="legend">
            <span><i class="dot good"></i>Good agents</span>
            <span><i class="dot bad"></i>Adversaries</span>
            <span><i class="dot obstacle"></i>Obstacles</span>
          </div>

          <div class="cards">
            <div class="card">
              <label>Current Agent Collisions</label>
              <strong id="agent-collisions">0</strong>
            </div>
            <div class="card">
              <label>Obstacle Contacts</label>
              <strong id="obstacle-collisions">0</strong>
            </div>
            <div class="card">
              <label>Nearest Cross-Team Gap</label>
              <strong id="cross-gap">0.00</strong>
            </div>
            <div class="card">
              <label>Mean Speed</label>
              <strong id="mean-speed">0.00</strong>
            </div>
          </div>
        </div>
      </div>

      <div class="stack">
        <div class="panel">
          <div class="panel-inner">
            <h2 class="section-title">Run Summary</h2>
            <div class="copy-box" id="summary-copy"></div>
          </div>
        </div>

        <div class="panel">
          <div class="panel-inner">
            <h2 class="section-title">Teams</h2>
            <div class="team-grid">
              <div class="team-row good">
                <strong>Good Agents</strong>
                <div class="metric"><span>Count</span><span id="good-count">0</span></div>
                <div class="metric"><span>Avg Reward</span><span id="good-reward">0.00</span></div>
                <div class="metric"><span>Centroid</span><span id="good-centroid">0.00, 0.00</span></div>
              </div>
              <div class="team-row adversary">
                <strong>Adversaries</strong>
                <div class="metric"><span>Count</span><span id="adversary-count">0</span></div>
                <div class="metric"><span>Avg Reward</span><span id="adversary-reward">0.00</span></div>
                <div class="metric"><span>Centroid</span><span id="adversary-centroid">0.00, 0.00</span></div>
              </div>
            </div>
          </div>
        </div>

        <div class="panel">
          <div class="panel-inner">
            <h2 class="section-title">Collision Timeline</h2>
            <svg id="timeline" class="timeline" viewBox="0 0 420 120"></svg>
          </div>
        </div>
      </div>
    </section>
  </div>

  <script id="visualization-data" type="application/json">__PAYLOAD__</script>
  <script>
    const data = JSON.parse(document.getElementById("visualization-data").textContent);
    const simulation = data.simulation;
    const frames = simulation.frames;
    const agents = simulation.agents;
    const landmarks = simulation.landmarks;

    const cycleRange = document.getElementById("cycle-range");
    const cycleLabel = document.getElementById("cycle-label");
    const stage = document.getElementById("stage");
    const playToggle = document.getElementById("play-toggle");
    const restartButton = document.getElementById("restart-button");
    const summaryCopy = document.getElementById("summary-copy");
    const goodCount = document.getElementById("good-count");
    const adversaryCount = document.getElementById("adversary-count");
    const goodReward = document.getElementById("good-reward");
    const adversaryReward = document.getElementById("adversary-reward");
    const goodCentroid = document.getElementById("good-centroid");
    const adversaryCentroid = document.getElementById("adversary-centroid");
    const agentCollisions = document.getElementById("agent-collisions");
    const obstacleCollisions = document.getElementById("obstacle-collisions");
    const crossGap = document.getElementById("cross-gap");
    const meanSpeed = document.getElementById("mean-speed");
    const timeline = document.getElementById("timeline");

    let playing = false;
    let timer = null;

    const teamCounts = simulation.team_counts;
    const teamRewards = simulation.team_reward_averages;
    const agentNames = Object.keys(agents);

    function mapCoordinate(value) {
      const bounds = 1.45;
      return 24 + ((value + bounds) / (bounds * 2)) * 652;
    }

    function centroidText(point) {
      return `${point[0].toFixed(2)}, ${point[1].toFixed(2)}`;
    }

    function renderSummary() {
      summaryCopy.textContent =
        `${teamCounts.good + teamCounts.adversary} total agents share one ` +
        `${simulation.environment || simulation.env_name} world with ${simulation.obstacle_count} obstacles. ` +
        `Across ${simulation.frame_count} frames, the run accumulated ${simulation.total_agent_collisions} ` +
        `agent-agent collisions and ${simulation.total_obstacle_contacts} obstacle contacts. ` +
        `Peak crowding reached ${simulation.peak_agent_collisions} simultaneous agent collisions in one frame.`;

      goodCount.textContent = String(teamCounts.good);
      adversaryCount.textContent = String(teamCounts.adversary);
      goodReward.textContent = teamRewards.good_average.toFixed(2);
      adversaryReward.textContent = teamRewards.adversary_average.toFixed(2);
    }

    function renderTimeline() {
      const maxCollision = Math.max(...frames.map((frame) => frame.metrics.agent_agent_collisions), 1);
      const points = frames.map((frame, index) => {
        const x = 14 + (index / Math.max(frames.length - 1, 1)) * 392;
        const y = 100 - (frame.metrics.agent_agent_collisions / maxCollision) * 78;
        return `${x.toFixed(2)},${y.toFixed(2)}`;
      }).join(" ");

      timeline.innerHTML = `
        <rect x="0" y="0" width="420" height="120" rx="16" fill="rgba(255,255,255,0.5)"></rect>
        <line x1="14" y1="100" x2="406" y2="100" stroke="rgba(74,59,41,0.18)" stroke-width="1"></line>
        <polyline points="${points}" fill="none" stroke="var(--bad)" stroke-width="3.5" stroke-linecap="round"></polyline>
        <text x="14" y="18" fill="#6f665d" font-size="12">Agent collisions over time</text>
        <text x="370" y="18" fill="#6f665d" font-size="12">peak ${simulation.peak_agent_collisions}</text>
      `;
    }

    function renderStage(frameIndex) {
      const frame = frames[frameIndex];

      const obstacleNodes = landmarks.map((landmark) => {
        const x = mapCoordinate(landmark.position[0]);
        const y = mapCoordinate(-landmark.position[1]);
        const radius = 30 + (landmark.size * 40);
        return `
          <circle cx="${x}" cy="${y}" r="${radius}" fill="var(--obstacle-soft)" stroke="var(--obstacle)" stroke-width="2.5"></circle>
          <text x="${x}" y="${y - radius - 6}" text-anchor="middle" fill="#5869b8" font-size="11">${landmark.name}</text>
        `;
      }).join("");

      const agentNodes = agentNames.map((agentName) => {
        const meta = agents[agentName];
        const point = frame.positions[agentName];
        const x = mapCoordinate(point[0]);
        const y = mapCoordinate(-point[1]);
        const radius = meta.team === "adversary" ? 5.2 : 4.4;
        const fill = meta.team === "adversary" ? "var(--bad)" : "var(--good)";
        const opacity = meta.team === "adversary" ? 0.86 : 0.82;
        return `<circle cx="${x}" cy="${y}" r="${radius}" fill="${fill}" fill-opacity="${opacity}"></circle>`;
      }).join("");

      const goodCenterX = mapCoordinate(frame.metrics.good_centroid[0]);
      const goodCenterY = mapCoordinate(-frame.metrics.good_centroid[1]);
      const adversaryCenterX = mapCoordinate(frame.metrics.adversary_centroid[0]);
      const adversaryCenterY = mapCoordinate(-frame.metrics.adversary_centroid[1]);

      stage.innerHTML = `
        <svg viewBox="0 0 700 700" aria-label="shared crowd simulation">
          <defs>
            <pattern id="grid" width="70" height="70" patternUnits="userSpaceOnUse">
              <path d="M 70 0 L 0 0 0 70" fill="none" stroke="rgba(74,59,41,0.10)" stroke-width="1"></path>
            </pattern>
          </defs>
          <rect x="0" y="0" width="700" height="700" fill="url(#grid)"></rect>
          <rect x="24" y="24" width="652" height="652" rx="24" fill="rgba(255,255,255,0.38)" stroke="rgba(74,59,41,0.10)"></rect>
          ${obstacleNodes}
          ${agentNodes}
          <circle cx="${goodCenterX}" cy="${goodCenterY}" r="14" fill="none" stroke="var(--good)" stroke-width="3" stroke-dasharray="8 8"></circle>
          <circle cx="${adversaryCenterX}" cy="${adversaryCenterY}" r="16" fill="none" stroke="var(--bad)" stroke-width="3" stroke-dasharray="10 8"></circle>
        </svg>
      `;

      cycleLabel.textContent = `Cycle ${frame.cycle} / ${frames.length - 1}`;
      goodCentroid.textContent = centroidText(frame.metrics.good_centroid);
      adversaryCentroid.textContent = centroidText(frame.metrics.adversary_centroid);
      agentCollisions.textContent = String(frame.metrics.agent_agent_collisions);
      obstacleCollisions.textContent = String(frame.metrics.agent_obstacle_contacts);
      crossGap.textContent = frame.metrics.nearest_cross_team_distance.toFixed(2);
      meanSpeed.textContent = frame.metrics.mean_speed.toFixed(2);
    }

    function setFrame(frameIndex) {
      cycleRange.value = String(frameIndex);
      renderStage(frameIndex);
    }

    function stopPlayback() {
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
      playing = false;
      playToggle.textContent = "Play";
    }

    function startPlayback() {
      stopPlayback();
      playing = true;
      playToggle.textContent = "Pause";
      timer = setInterval(() => {
        const current = Number(cycleRange.value);
        const next = current + 1 >= frames.length ? 0 : current + 1;
        setFrame(next);
      }, 150);
    }

    cycleRange.max = String(Math.max(frames.length - 1, 0));
    cycleRange.addEventListener("input", () => {
      renderStage(Number(cycleRange.value));
    });

    playToggle.addEventListener("click", () => {
      if (playing) {
        stopPlayback();
      } else {
        startPlayback();
      }
    });

    restartButton.addEventListener("click", () => {
      stopPlayback();
      setFrame(0);
    });

    renderSummary();
    renderTimeline();
    setFrame(0);
  </script>
</body>
</html>
""".replace("__PAYLOAD__", json.dumps(payload))


def summarize(messages: list[dict]) -> dict:
    simulation = parse_simulation(messages[0])

    return {
        "mode": simulation["mode"],
        "environment": simulation["env_name"],
        "policy_mode": simulation["policy_mode"],
        "seed": simulation["seed"],
        "team_counts": simulation["team_counts"],
        "obstacle_count": simulation["obstacle_count"],
        "frame_count": simulation["frame_count"],
        "max_cycles": simulation["max_cycles"],
        "team_reward_averages": simulation["team_reward_averages"],
        "total_agent_collisions": simulation["total_agent_collisions"],
        "total_obstacle_contacts": simulation["total_obstacle_contacts"],
        "peak_agent_collisions": simulation["peak_agent_collisions"],
        "peak_obstacle_contacts": simulation["peak_obstacle_contacts"],
        "visualization_html": build_html(simulation),
    }


def main() -> None:
    incoming = load_input()
    messages = incoming.get("messages", [])
    print(json.dumps({"complete_job": summarize(messages)}))


if __name__ == "__main__":
    main()
