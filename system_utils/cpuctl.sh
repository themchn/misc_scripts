#!/bin/bash


# cpu0 cannot be disabled so it can always be used as a baseline
cpu_sys_path='/sys/devices/system/cpu/cpu'
clock_path='cpufreq/scaling_max_freq'
cur_max_clock="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
gov_path='cpufreq/scaling_governor'

# defaults
max_clock="4700000"
base_clock="2800000"
half_clock="1400000"
idle_clock="700000"
min_clock="400000"

dbus_notify() {
dbus-send --type=method_call --dest=org.freedesktop.Notifications \
/org/freedesktop/Notifications org.freedesktop.Notifications.Notify \
string:'[APPLICATION]' \
uint32:1 string:'[ICON]' \
string:'' \
string:"$@" \
array:string:'' \
dict:string:string:'','' \
int32:2000
}

tee_to_cpu() {
# cleanest way to sudo tee across all cores
for cpu in "$cpu_sys_path"? ; do
    echo "$1" | sudo tee "$cpu"/"$2" &> /dev/null
done
}

set_clock() {
if [[ "$1" == cycle ]] ; then
    case "$cur_max_clock" in
        "$idle_clock")
            clock_to_set="$half_clock"
            ;;
        "$half_clock")
            clock_to_set="$base_clock"
            ;;
        "$base_clock")
            clock_to_set="$max_clock"
            ;;
        "$max_clock")
            clock_to_set="$idle_clock"
            ;;
        *)
            clock_to_set="$base_clock"
            ;;
    esac
    tee_to_cpu "$clock_to_set" "$clock_path"
else
    clock_to_set="$1"
    tee_to_cpu "$clock_to_set" "$clock_path"
fi
}

set_gov() {
# cycle between power save and performance, the only governers supported on my system
if [[ "$gov_to_set" == cycle ]] ; then
cur_gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    if [[ "$cur_gov" == powersave ]] ; then
        tee_to_cpu performance "$gov_path"
    else
        tee_to_cpu powersave "$gov_path"
    fi
else
    tee_to_cpu "$gov_to_set" "$gov_path"
fi
}

set_cores() {
#TODO this should be dynamic so it can run on any system
# that would require determining which cores belong to each pysical core for optimal perf
# Do so by enabling all available then pulling info from /proc/cpuinfo
if [[ "$1" == cycle ]] ; then
    let cores_to_enable="($(cat /sys/devices/system/cpu/cpu*/online | grep 1 | wc -l)+1)/2+1"
else
    cores_to_enable="$1"
fi
case "$cores_to_enable" in
    1|5)
        echo 1 | sudo tee /sys/devices/system/cpu/cpu{4}/online
        echo 0 | sudo tee /sys/devices/system/cpu/cpu{1,5,2,6,3,7}/online
        ;;
    2)
        echo 1 | sudo tee /sys/devices/system/cpu/cpu{4,1,5}/online
        echo 0 | sudo tee /sys/devices/system/cpu/cpu{2,6,3,7}/online
        ;;
    3)
        echo 1 | sudo tee /sys/devices/system/cpu/cpu{4,1,5,2,6}/online
        echo 0 | sudo tee /sys/devices/system/cpu/cpu{3,7}/online
        ;;
    4)
        echo 1 | sudo tee /sys/devices/system/cpu/cpu{4,1,5,2,6,3,7}/online
        ;;
esac
tee_to_cpu "$cur_max_clock" "$clock_path"
}

set_profile() {
case "$1" in
    min)
        set_cores 1
        set_clock "$min_clock"
        set_gov powersave
        ;;
    idle)
        set_cores 1
        set_clock "$idle_clock"
        set_gov powersave
        ;;
    low)
        set_cores 1
        set_clock "$half_clock"
        set_gov powersave
        ;;
    mid)
        set_cores 2
        set_clock "$base_clock"
        set_gov powersave
        ;;
    full)
        set_cores 4
        set_clock "$base_clock"
        set_gov powersave
        ;;
    turbo)
        set_cores 4
        set_clock "$max_clock"
        set_gov performance
        ;;
esac
}

restore_profile() {
readarray -d' ' saved_profile < <(cat /tmp/cpuctl_profile)
set_cores "${saved_profile[0]}"
set_clock "${saved_profile[1]}"
set_gov "${saved_profile[2]}"
}

options=$(getopt -o hqp: --longoptions cores:,clock:,gov:,profile:,help -- "$@")
[ $? -eq 0 ] || {
    echo "Incorrect options provided. Use -h to view help."
    exit 1
}
eval set -- "$options"
while true; do
    case "$1" in
    -h|--help)
        help="1"
        ;;
    -q|--quiet)
        quiet="1"
        ;;
    -p|--profile)
        profile="$2"
        set_profile "$profile"
        ;;
    --cores)
        cores_to_enable="$2"
        set_cores "$cores_to_enable"
        ;;
    --clock)
        set_clock "$2"
        ;;
    --gov)
        gov_to_set="$2"
        set_gov "$gov_to_set"
        ;;
    --no-save)
        no_save=1
        ;;
    --restore)
        no_save=1
        restore_profile
        ;;
    --)
        shift
        break
        ;;
    esac
    shift
done

cur_gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
cur_max_clock="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
cur_core_count="$(expr \( $(cat /sys/devices/system/cpu/cpu*/online | grep 1 | wc -l) + 1 \) / 2)"
pretty_gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor | sed 's/^./\u&/')"
plain_clockspeed="$(echo "$cur_max_clock" | sed 's/0//g')"
clock_digit_count="$(expr $(echo "$plain_clockspeed" | wc -m) - 1)"

if [[ "$no_save" = 1 ]] ; then
    :
else
    echo ""$cur_core_count" "$cur_max_clock" "$cur_gov" "$profile"" > /tmp/cpuctl_profile
fi

if [[ "$quiet" == 1 ]] ; then
    :
else
    if [[ "$clock_digit_count" > 1 ]] ; then
        pretty_clockspeed=""$(echo "$plain_clockspeed" | sed 's/^./&\./')"GHz"
    else
        pretty_clockspeed=""$plain_clockspeed"00MHz"
    fi
    
    notify_message="Cores: "$cur_core_count" Clock: "$pretty_clockspeed" Governor: "$pretty_gov""
    echo "$notify_message"
    dbus_notify "$notify_message"
fi
