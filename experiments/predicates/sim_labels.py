"""Automatic predicate labels from ManiSkill trajectories (RoboFAC simulation data).

usage: sim_labels.py [--root ~/data/robot/robofac_sim/simulation_data] [--tasks PickCube-v1 ...] [--out ~/data/robot/sim_labels.json] [--check]
 - For every episode whose video exists, reads the actor poses and the Panda joint state of each step, computes the end-effector (TCP) pose by forward kinematics,
   and evaluates the predicates of predicates.json (the thresholds are read from there) at every step and over the whole video.
 - Output: {episode: {task, folder, steps, success, state: {pred: [bool per step]}, event: {pred: bool}}}. One video frame per step (+1 for the first frame).
 - --check prints, per task and folder, how often each predicate is true, and compares them with the dataset's own success flag and the folder name (which says which error was injected).
Objects: PickCube/PushCube/PullCube have `cube` (+ `goal_site` or `goal_region`); StackCube has `cubeA` (moved) and `cubeB` (target).
"""
import argparse, collections, glob, json, os
import h5py, numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REG = {p["id"]: p for p in json.load(open(f"{HERE}/predicates.json"))["predicates"]}
P = lambda name, key: REG[name]["params"][key]
# The size of the goal differs per task (ManiSkill's own success radius: found from the dataset's success flags, e.g. push/pull succeed at <= 0.097 m and fail at >= 0.102 m).
GOAL_TOL = {"pick": 0.025, "push": 0.10, "pull": 0.10, "stack": 0.02}

def quat_to_mat(q):  # wxyz
    w, x, y, z = q
    return np.array([[1 - 2*(y*y + z*z), 2*(x*y - z*w), 2*(x*z + y*w)], [2*(x*y + z*w), 1 - 2*(x*x + z*z), 2*(y*z - x*w)], [2*(x*z - y*w), 2*(y*z + x*w), 1 - 2*(x*x + y*y)]])

def dh(a, d, alpha, theta):  # modified (Craig) DH
    ca, sa, ct, st = np.cos(alpha), np.sin(alpha), np.cos(theta), np.sin(theta)
    return np.array([[ct, -st, 0, a], [st*ca, ct*ca, -sa, -d*sa], [st*sa, ct*sa, ca, d*ca], [0, 0, 0, 1]])

A = [0, 0, 0, 0.0825, -0.0825, 0, 0.088]; D = [0.333, 0, 0.316, 0, 0.384, 0, 0]; AL = [0, -np.pi/2, np.pi/2, np.pi/2, -np.pi/2, np.pi/2, np.pi/2]
def tcp_positions(art):
    """(T, 3) end-effector point between the fingertips, in world coordinates. art: (T, 31) = root pose 7, root vel 6, qpos 9, qvel 9."""
    out = []
    for row in art:
        base = np.eye(4); base[:3, :3] = quat_to_mat(row[3:7]); base[:3, 3] = row[:3]
        T = base
        for i in range(7): T = T @ dh(A[i], D[i], AL[i], row[13 + i])
        T = T @ dh(0, 0.107 + 0.1034, 0, 0)  # flange -> hand -> fingertip center
        out.append(T[:3, 3])
    return np.array(out)

def labels(h5file, traj, kind):
    t = h5file[traj]; act = t["env_states/actors"]; art = t["env_states/articulations"]
    panda = art[[k for k in art if k.startswith("panda")][0]][:]
    obj = act["cubeA" if kind == "stack" else "cube"][:, :3]
    target = act["cubeB"][:, :3] if kind == "stack" else act[[k for k in act if k.startswith("goal")][0]][:, :3]
    tcp = tcp_positions(panda); finger = panda[:, 13 + 7] + panda[:, 13 + 8]  # total opening of the two fingers
    dist_tcp = np.linalg.norm(tcp - obj, axis=1)
    dist_goal_xy = np.linalg.norm(obj[:, :2] - target[:, :2], axis=1)
    dist_goal = np.linalg.norm(obj - target, axis=1) if kind == "pick" else dist_goal_xy  # PickCube's goal floats in the air: use the 3-D distance
    tol = GOAL_TOL[kind]
    rest = obj[0, 2]; lifted = obj[:, 2] - rest > P("lifted", "h_lift_m")
    close = (dist_tcp < P("holding", "d_hold_m")) & (finger < 0.07)
    moving_with = np.r_[False, np.linalg.norm(np.diff(obj, axis=0) - np.diff(tcp, axis=0), axis=1) < 0.01]
    holding = close & moving_with & (finger > 0.001)
    if kind == "stack": at_goal = (dist_goal_xy < P("on_top", "dxy_tol_m")) & (np.abs(obj[:, 2] - target[:, 2] - 0.04) < P("on_top", "dz_tol_m"))
    else: at_goal = dist_goal < tol
    state = {"holding": holding, "lifted": lifted, "at_goal": at_goal, "near_goal": (~at_goal) & (dist_goal < tol + P("near_goal", "d_near_m") / 2),
             "touching": dist_tcp < P("touching", "d_touch_m") + 0.03, "gripper_closed": finger < P("gripper_closed", "w_closed_m") * 2 + 0.0,
             "gripper_empty_closed": finger < P("gripper_empty_closed", "w_empty_m")}
    disp = np.linalg.norm(obj[-1] - obj[0]); start_goal = np.linalg.norm(obj[0, :2] - target[0, :2]); direction = (target[0, :2] - obj[0, :2]) / max(start_goal, 1e-6)
    progress = float((obj[-1, :2] - obj[0, :2]) @ direction)  # signed distance moved toward the goal along start→goal
    event = {"reached": bool(dist_tcp.min() < P("reached", "d_reach_m")), "grasped": bool((holding & lifted).any()), "moved": bool(disp > P("moved", "d_move_m")),
             "dropped": bool(holding.any() and (not holding[-1]) and obj[-1, 2] - rest > 0.005 or (holding[:-1] & ~holding[1:] & (obj[1:, 2] - rest > 0.01)).any()),
             "overshot": bool(progress - start_goal > P("overshot", "d_over_m")), "fell_short": bool(start_goal - progress > P("fell_short", "d_short_m") and not at_goal[-1])}
    return {"state": {k: v.tolist() for k, v in state.items()}, "event": event, "final_goal_dist": float(dist_goal_xy[-1]), "min_tcp_dist": float(dist_tcp.min()), "steps": len(obj) - 1}

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--root", default="~/data/robot/robofac_sim/simulation_data"); ap.add_argument("--out", default="~/data/robot/sim_labels.json")
    ap.add_argument("--tasks", nargs="*", default=["PickCube-v1", "PushCube-v1", "PullCube-v1", "StackCube-v1"]); ap.add_argument("--check", action="store_true")
    a = ap.parse_args(); root = os.path.expanduser(a.root); out = {}
    for task in a.tasks:
        kind = {"PickCube": "pick", "PushCube": "push", "PullCube": "pull", "StackCube": "stack"}[task.split("-")[0]]
        for h5path in sorted(glob.glob(f"{root}/{task}/*/*.h5")):
            folder = os.path.dirname(h5path); meta = json.load(open(h5path.replace(".h5", ".json")))["episodes"]; f = h5py.File(h5path)
            for ep in meta:
                video = f"{folder}/{ep['unique_id']}.mp4"
                if not os.path.exists(video): continue
                lab = labels(f, f"traj_{ep['episode_id']}", kind)
                out[f"{task}/{os.path.basename(folder)}/{ep['unique_id']}"] = {"task": task, "folder": os.path.basename(folder), "success": ep["success"], "video": os.path.relpath(video, root), **lab}
    json.dump(out, open(os.path.expanduser(a.out), "w")); print(len(out), "episodes labelled ->", a.out)
    if a.check:
        groups = collections.defaultdict(list)
        for k, v in out.items(): groups[(v["task"], v["folder"])].append(v)
        names = ["reached", "grasped", "moved", "dropped", "overshot", "fell_short"]
        print(f"{'task / folder':<62}{'n':>4}{'succ':>6}{'end@goal':>9}" + "".join(f"{n[:8]:>9}" for n in names))
        for (task, folder), vs in sorted(groups.items()):
            r = lambda f: f"{100*np.mean([f(v) for v in vs]):.0f}%"
            print(f"{(task + ' / ' + folder)[:61]:<62}{len(vs):>4}{r(lambda v: v['success']):>6}{r(lambda v: v['state']['at_goal'][-1]):>9}" + "".join(f"{r(lambda v, n=n: v['event'][n]):>9}" for n in names))
        ok = [v for v in out.values() if v["success"]]; print("\nepisodes the dataset marks as success:", len(ok), "| of these the final frame has at_goal =", f"{100*np.mean([v['state']['at_goal'][-1] for v in ok]):.0f}%" if ok else "-")
        bad = [v for v in out.values() if not v["success"]]; print("failures:", len(bad), "| final at_goal =", f"{100*np.mean([v['state']['at_goal'][-1] for v in bad]):.0f}%" if bad else "-")

if __name__ == "__main__": main()
