#!/bin/bash

# 检查 ssh 命令是否存在
if command -v ssh > /dev/null; then
  # 获取 ssh 版本号
  ssh_version=$(ssh -V 2>&1)
  if [[ $ssh_version =~ OpenSSH_([0-9]+)\.([0-9]+) ]]; then
    major_version=${BASH_REMATCH[1]}
    minor_version=${BASH_REMATCH[2]}
    
    # 检查版本号是否在 8.5 至 9.8p1（不含）范围内
    if { [ "$major_version" -eq 8 ] && [ "$minor_version" -ge 5 ]; } || { [ "$major_version" -eq 9 ] && [ "$minor_version" -le 7 ]; } || { [ "$major_version" -eq 9 ] && [ "$minor_version" -eq 8 ] && [[ ! $ssh_version =~ 9\.8p1 ]]; }; then
      exit 1
    else
      exit 0
    fi
  else
    # 无法解析版本号
    exit 3
  fi
else
  # ssh 命令不存在
  exit 2
fi
