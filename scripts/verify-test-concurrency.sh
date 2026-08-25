#!/bin/zsh

set -euo pipefail

iterations=20
scope=focused
parallel=true

usage() {
    print -r -- "用法: $0 [--iterations N] [--full] [--no-parallel]"
    print -r -- "  --iterations N  连续运行次数，默认 20"
    print -r -- "  --full          运行完整测试集；默认只运行七个异步问题套件"
    print -r -- "  --no-parallel   使用 SwiftPM 串行诊断模式"
}

while (( $# > 0 )); do
    case "$1" in
        --iterations)
            if (( $# < 2 )) || [[ ! "$2" =~ '^[1-9][0-9]*$' ]]; then
                print -u2 -r -- "--iterations 需要正整数。"
                exit 2
            fi
            iterations="$2"
            shift 2
            ;;
        --full)
            scope=full
            shift
            ;;
        --no-parallel)
            parallel=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 -r -- "未知参数：$1"
            usage >&2
            exit 2
            ;;
    esac
done

focused_filter='AutomaticRefreshWaitCoordinatorTests|DeviceConnectionStabilityViewModelTests|RefreshSequenceTests|MenuBarViewModelDeploymentVerificationTests|MenuBarViewModelDeviceDetectionSafetyTests|MenuBarViewModelNotificationTests|MenuBarViewModelRecoveryTests'

for (( iteration = 1; iteration <= iterations; iteration++ )); do
    print -r -- "[并发验收] 第 ${iteration}/${iterations} 次"
    test_command=(swift test)
    if [[ -n "${SWIFT_TEST_SCRATCH_PATH:-}" ]]; then
        test_command+=(--scratch-path "$SWIFT_TEST_SCRATCH_PATH")
    fi
    if [[ "$parallel" == false ]]; then
        test_command+=(--no-parallel)
    fi
    if [[ "$scope" == focused ]]; then
        test_command+=(--filter "$focused_filter")
    fi
    "${test_command[@]}"
done

print -r -- "[并发验收] ${iterations} 次全部通过。"
