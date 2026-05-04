import numpy as np
import click
from scipy.spatial.transform import Rotation as R
from scipy.spatial.transform import Slerp
import os


# 从color_poses.txt中读取矩阵
def load_poses(file_path):
    with open(file_path, 'r') as f:
        lines = f.readlines()

    poses = []
    current_pose = []

    for line in lines:
        values = list(map(float, line.strip().split()))
        current_pose.append(values)

        if len(current_pose) == 4:
            poses.append(np.array(current_pose))
            current_pose = []

    return np.array(poses)


# 在两个姿态之间进行插值
def inter_two_poses(pose_a, pose_b, alpha):
    ret = np.zeros([4, 4], dtype=np.float64)
    rot_a = R.from_matrix(pose_a[:3, :3])
    rot_b = R.from_matrix(pose_b[:3, :3])

    key_rots = R.from_matrix(np.stack([pose_a[:3, :3], pose_b[:3, :3]], 0))
    key_times = [0, 1]
    slerp = Slerp(key_times, key_rots)
    rot = slerp(alpha)

    ret[:3, :3] = rot.as_matrix()
    ret[:3, 3] = pose_a[:3, 3] * (1 - alpha) + pose_b[:3, 3] * alpha
    ret[3, 3] = 1.0
    return ret


# 生成插值的姿态
def generate_interpolated_poses(poses, num_interpolations):
    inter_poses = []

    for i in range(len(poses) - 1):
        inter_poses.append(poses[i])
        for j in range(1, num_interpolations):
            alpha = j / num_interpolations
            interpolated_pose = inter_two_poses(poses[i], poses[i + 1], alpha)
            inter_poses.append(interpolated_pose)

    inter_poses.append(poses[-1])
    return np.array(inter_poses)


# 将结果保存到文件
def save_interpolated_poses(file_path, poses):
    with open(file_path, 'w') as f:
        for pose in poses:
            for row in pose:
                f.write(' '.join(map(str, row)) + '\n')


@click.command()
@click.option('--data_dir', type=str, required=True, help="directory containing color_poses.txt")
@click.option('--key_poses', type=str, required=False, help="comma-separated key-frame indices, 'all', or 'skip'")
@click.option('--skip', type=int, default=5, help="key-frame stride when --key_poses=skip")
@click.option('--n_out_poses', type=int, default=240, help="total interpolated poses to output")
@click.option('--output_file', type=str, default=None, help="explicit output path; default is <data_dir>/inter_color_poses.txt")
def interpolate_poses(data_dir, key_poses, n_out_poses, skip, output_file):
    input_file = os.path.join(data_dir, 'color_poses.txt')
    if output_file is None:
        output_file = os.path.join(data_dir, 'inter_color_poses.txt')
    os.makedirs(os.path.dirname(os.path.abspath(output_file)), exist_ok=True)

    # 读取姿态
    poses = load_poses(input_file)

    # 根据命令行参数选择关键帧
    if key_poses == 'all':
        selected_poses = poses
    elif key_poses == 'skip':
        selected_poses = poses[::skip]
    else:
        key_indices = [int(idx) for idx in key_poses.split(',')]
        selected_poses = poses[key_indices]

    # 生成插值姿态
    interpolated_poses = generate_interpolated_poses(selected_poses, n_out_poses // (len(selected_poses) - 1))

    # 保存插值后的姿态
    save_interpolated_poses(output_file, interpolated_poses)
    print(f"插值后的姿态已保存到 {output_file}")


if __name__ == '__main__':
    interpolate_poses()
