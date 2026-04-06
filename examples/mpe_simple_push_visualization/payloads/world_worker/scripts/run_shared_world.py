#!/usr/bin/env python3
import json
import math
import os
import warnings
from pathlib import Path


warnings.filterwarnings("ignore", category=DeprecationWarning)


def load_input() -> dict:
    return json.loads(Path(os.environ["MIRROR_NEURON_INPUT_FILE"]).read_text())


def import_simple_tag():
    try:
        from mpe2 import simple_tag_v3

        return simple_tag_v3, "mpe2.simple_tag_v3"
    except ImportError:
        from pettingzoo.mpe import simple_tag_v3

        return simple_tag_v3, "pettingzoo.mpe.simple_tag_v3"


def vector(point_a, point_b) -> tuple[float, float]:
    return (float(point_b[0] - point_a[0]), float(point_b[1] - point_a[1]))


def magnitude(delta_x: float, delta_y: float) -> float:
    return math.sqrt((delta_x * delta_x) + (delta_y * delta_y))


def distance(point_a, point_b) -> float:
    delta_x, delta_y = vector(point_a, point_b)
    return magnitude(delta_x, delta_y)


def unit(delta_x: float, delta_y: float) -> tuple[float, float]:
    size = magnitude(delta_x, delta_y)
    if size <= 1e-9:
        return (0.0, 0.0)
    return (delta_x / size, delta_y / size)


def scaled(delta_x: float, delta_y: float, weight: float) -> tuple[float, float]:
    return (delta_x * weight, delta_y * weight)


def add_vectors(*vectors: tuple[float, float]) -> tuple[float, float]:
    return (sum(vector[0] for vector in vectors), sum(vector[1] for vector in vectors))


def action_toward(delta_x: float, delta_y: float) -> int:
    if abs(delta_x) < 0.03 and abs(delta_y) < 0.03:
        return 0

    if abs(delta_x) >= abs(delta_y):
        return 2 if delta_x > 0 else 1

    return 4 if delta_y > 0 else 3


def average_position(agents) -> list[float]:
    if not agents:
        return [0.0, 0.0]

    pos_x = sum(float(agent.state.p_pos[0]) for agent in agents) / len(agents)
    pos_y = sum(float(agent.state.p_pos[1]) for agent in agents) / len(agents)
    return [round(pos_x, 5), round(pos_y, 5)]


def to_pair(value) -> list[float]:
    return [round(float(value[0]), 5), round(float(value[1]), 5)]


def deterministic_wobble(index: int, cycle: int) -> tuple[float, float]:
    angle = (index * 0.73) + (cycle * 0.19)
    return (math.cos(angle) * 0.14, math.sin(angle) * 0.14)


def nearest(agent, others):
    nearest_target = None
    nearest_distance = float("inf")

    for candidate in others:
        if candidate is agent:
            continue
        delta = distance(agent.state.p_pos, candidate.state.p_pos)
        if delta < nearest_distance:
            nearest_distance = delta
            nearest_target = candidate

    return nearest_target, nearest_distance


def repulsion(agent, neighbors, radius: float, weight: float) -> tuple[float, float]:
    total_x = 0.0
    total_y = 0.0

    for neighbor in neighbors:
        if neighbor is agent:
            continue
        delta_x, delta_y = vector(neighbor.state.p_pos, agent.state.p_pos)
        gap = magnitude(delta_x, delta_y)
        if gap <= 1e-9 or gap > radius:
            continue
        unit_x, unit_y = unit(delta_x, delta_y)
        strength = (radius - gap) / radius
        total_x += unit_x * strength * weight
        total_y += unit_y * strength * weight

    return (total_x, total_y)


def obstacle_repulsion(agent, obstacles, radius: float, weight: float) -> tuple[float, float]:
    total_x = 0.0
    total_y = 0.0

    for obstacle in obstacles:
        delta_x, delta_y = vector(obstacle.state.p_pos, agent.state.p_pos)
        gap = magnitude(delta_x, delta_y) - float(obstacle.size)
        if gap <= 1e-9 or gap > radius:
            continue
        unit_x, unit_y = unit(delta_x, delta_y)
        strength = (radius - gap) / radius
        total_x += unit_x * strength * weight
        total_y += unit_y * strength * weight

    return (total_x, total_y)


def choose_actions(env, world, policy_mode: str, cycle: int) -> dict[str, int]:
    if policy_mode == "random":
        return {agent.name: int(env.action_space(agent.name).sample()) for agent in world.agents}

    good_agents = [agent for agent in world.agents if not agent.adversary]
    adversaries = [agent for agent in world.agents if agent.adversary]
    obstacles = list(world.landmarks)

    actions = {}

    for index, agent in enumerate(world.agents):
        team = adversaries if agent.adversary else good_agents
        enemies = good_agents if agent.adversary else adversaries

        nearest_enemy, _ = nearest(agent, enemies)
        team_center = average_position(team)
        center_vector = vector(agent.state.p_pos, team_center)
        same_team_push = repulsion(agent, team, radius=0.22, weight=1.05)
        obstacle_push = obstacle_repulsion(agent, obstacles, radius=0.34, weight=0.85)
        wobble = deterministic_wobble(index, cycle)

        if nearest_enemy is None:
            chase_or_flee = wobble
        else:
            delta_to_enemy = vector(agent.state.p_pos, nearest_enemy.state.p_pos)
            unit_x, unit_y = unit(delta_to_enemy[0], delta_to_enemy[1])

            if agent.adversary:
                chase_or_flee = scaled(unit_x, unit_y, 1.25)
            else:
                chase_or_flee = scaled(-unit_x, -unit_y, 1.1)

        if agent.adversary:
            drift = scaled(center_vector[0], center_vector[1], -0.18)
        else:
            drift = scaled(center_vector[0], center_vector[1], 0.08)

        move_x, move_y = add_vectors(chase_or_flee, same_team_push, obstacle_push, drift, wobble)
        actions[agent.name] = action_toward(move_x, move_y)

    return actions


def collision_metrics(world) -> dict:
    agents = list(world.agents)
    obstacles = list(world.landmarks)
    agent_agent = 0
    cross_team = 0
    same_team = 0

    for index, left in enumerate(agents):
        for right in agents[index + 1 :]:
            if distance(left.state.p_pos, right.state.p_pos) < float(left.size + right.size):
                agent_agent += 1
                if bool(left.adversary) == bool(right.adversary):
                    same_team += 1
                else:
                    cross_team += 1

    agent_obstacle = 0
    for agent in agents:
        for obstacle in obstacles:
            if distance(agent.state.p_pos, obstacle.state.p_pos) < float(agent.size + obstacle.size):
                agent_obstacle += 1

    good_agents = [agent for agent in agents if not agent.adversary]
    adversaries = [agent for agent in agents if agent.adversary]
    nearest_cross_team = float("inf")

    for good_agent in good_agents:
        for adversary in adversaries:
            nearest_cross_team = min(
                nearest_cross_team,
                distance(good_agent.state.p_pos, adversary.state.p_pos),
            )

    if nearest_cross_team == float("inf"):
        nearest_cross_team = 0.0

    mean_speed = 0.0
    if agents:
        mean_speed = sum(
            magnitude(float(agent.state.p_vel[0]), float(agent.state.p_vel[1])) for agent in agents
        ) / len(agents)

    return {
        "agent_agent_collisions": agent_agent,
        "cross_team_collisions": cross_team,
        "same_team_collisions": same_team,
        "agent_obstacle_contacts": agent_obstacle,
        "nearest_cross_team_distance": round(nearest_cross_team, 5),
        "mean_speed": round(mean_speed, 5),
        "good_centroid": average_position(good_agents),
        "adversary_centroid": average_position(adversaries),
    }


def capture_frame(cycle: int, world, rewards: dict[str, float]) -> dict:
    metrics = collision_metrics(world)

    positions = {agent.name: to_pair(agent.state.p_pos) for agent in world.agents}
    velocities = {agent.name: to_pair(agent.state.p_vel) for agent in world.agents}

    good_reward_values = [
        float(rewards.get(agent.name, 0.0))
        for agent in world.agents
        if not agent.adversary
    ]
    adversary_reward_values = [
        float(rewards.get(agent.name, 0.0))
        for agent in world.agents
        if agent.adversary
    ]

    metrics["good_step_reward"] = round(
        sum(good_reward_values) / max(len(good_reward_values), 1), 5
    )
    metrics["adversary_step_reward"] = round(
        sum(adversary_reward_values) / max(len(adversary_reward_values), 1), 5
    )

    return {
        "cycle": cycle,
        "positions": positions,
        "velocities": velocities,
        "metrics": metrics,
    }


def team_reward_averages(world, cumulative_rewards: dict[str, float]) -> dict:
    good_rewards = []
    adversary_rewards = []

    for agent in world.agents:
        reward = float(cumulative_rewards.get(agent.name, 0.0))
        if agent.adversary:
            adversary_rewards.append(reward)
        else:
            good_rewards.append(reward)

    return {
        "good_average": round(sum(good_rewards) / max(len(good_rewards), 1), 5),
        "adversary_average": round(sum(adversary_rewards) / max(len(adversary_rewards), 1), 5),
    }


def main() -> None:
    input_payload = load_input()
    simple_tag_v3, env_name = import_simple_tag()

    seed = int(os.environ["SIMULATION_SEED"])
    max_cycles = int(os.environ.get("MAX_CYCLES", "60"))
    num_good = int(os.environ.get("NUM_GOOD", "25"))
    num_adversaries = int(os.environ.get("NUM_ADVERSARIES", "75"))
    num_obstacles = int(os.environ.get("NUM_OBSTACLES", "8"))
    policy_mode = os.environ.get("POLICY_MODE", "swarm")

    env = simple_tag_v3.parallel_env(
        num_good=num_good,
        num_adversaries=num_adversaries,
        num_obstacles=num_obstacles,
        max_cycles=max_cycles,
        render_mode=None,
    )

    try:
        env.reset(seed=seed)
        world = env.unwrapped.world
        cumulative_rewards = {agent.name: 0.0 for agent in world.agents}
        zero_rewards = {agent.name: 0.0 for agent in world.agents}
        frames = [capture_frame(0, world, zero_rewards)]
        collision_total = 0
        obstacle_contact_total = 0

        while env.agents:
            cycle = len(frames)
            actions = choose_actions(env, world, policy_mode, cycle)
            _, rewards, terminations, truncations, _ = env.step(actions)

            for agent_name, reward in rewards.items():
                cumulative_rewards[agent_name] = cumulative_rewards.get(agent_name, 0.0) + float(reward)

            frame = capture_frame(cycle, world, rewards)
            collision_total += int(frame["metrics"]["agent_agent_collisions"])
            obstacle_contact_total += int(frame["metrics"]["agent_obstacle_contacts"])
            frames.append(frame)

            if all(terminations.values()) or all(truncations.values()):
                break

        team_counts = {
            "good": sum(1 for agent in world.agents if not agent.adversary),
            "adversary": sum(1 for agent in world.agents if agent.adversary),
        }

        result = {
            "mode": "mpe_shared_world_visualization",
            "env_name": env_name,
            "seed": seed,
            "policy_mode": policy_mode,
            "max_cycles": max_cycles,
            "input": input_payload,
            "team_counts": team_counts,
            "obstacle_count": len(world.landmarks),
            "agents": {
                agent.name: {
                    "team": "adversary" if agent.adversary else "good",
                    "size": round(float(agent.size), 5),
                    "max_speed": round(float(agent.max_speed), 5),
                }
                for agent in world.agents
            },
            "landmarks": [
                {
                    "name": landmark.name,
                    "size": round(float(landmark.size), 5),
                    "position": to_pair(landmark.state.p_pos),
                }
                for landmark in world.landmarks
            ],
            "frames": frames,
            "frame_count": len(frames),
            "cumulative_rewards": {
                agent_name: round(value, 5) for agent_name, value in cumulative_rewards.items()
            },
            "team_reward_averages": team_reward_averages(world, cumulative_rewards),
            "total_agent_collisions": collision_total,
            "total_obstacle_contacts": obstacle_contact_total,
            "peak_agent_collisions": max(
                frame["metrics"]["agent_agent_collisions"] for frame in frames
            ),
            "peak_obstacle_contacts": max(
                frame["metrics"]["agent_obstacle_contacts"] for frame in frames
            ),
        }

        print(json.dumps(result))
    finally:
        env.close()


if __name__ == "__main__":
    main()
