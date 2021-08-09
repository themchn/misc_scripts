#!/bin/bash

# cpu0 cannot be disabled so it can always be used as a baseline
cpu_sys_path='/sys/devices/system/cpu/cpu'
clock_path='cpufreq/scaling_max_freq'
cur_max_clock="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
gov_path='cpufreq/scaling_governor'
# defaults
turbo_clock="4700000"
base_clock="2800000"
half_clock="1400000"
idle_clock="700000"

#TODO make this notify function it's own script to source in all other scripts
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
#    echo "$cpu"/"$2"
done
}

cycle_clock() {
# cycle between predefined clock speeds from defaults
if [[ -n "$1" ]] ; then
    clock_to_set="$1"
    tee_to_cpu "$clock_to_set" "$clock_path"
else
    case "$cur_max_clock" in
        "$idle_clock")
            clock_to_set="$half_clock"
            ;;
        "$half_clock")
            clock_to_set="$base_clock"
            ;;
        "$base_clock")
            clock_to_set="$turbo_clock"
            ;;
        "$turbo_clock")
            clock_to_set="$idle_clock"
            ;;
        *)
            tee_to_cpu "$base_clock" "$clock_path"
            ;;
    esac
    tee_to_cpu "$clock_to_set" "$clock_path"
fi
}

cycle_governor() {
# cycle between power save and performance, the only governers supported on my system
cur_gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
if [[ "$cur_gov" == powersave ]] ; then
    tee_to_cpu performance "$gov_path"
else
    tee_to_cpu powersave "$gov_path"
fi
}

cycle_cores() {
#TODO this should be dynamic so it can run on any system
# that would require determining which cores belong to each pysical core for optimal perf
# Do so by enabling all available then pulling info from /proc/cpuinfo
# save current cores to revert to
if [[ -n "$1" ]] ; then
    cores_to_enable="$1"
else
    let cores_to_enable="\($(cat /sys/devices/system/cpu/cpu*/online | grep 1 | wc -l)+1\)/2+1"
fi
case "$cores_to_enable" in
    1)
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
   *)
        dbus_notify "Invalid input for cores"
        ;;
esac
tee_to_cpu "$cur_max_clock" "$clock_path"
}

cycle_profiles() {
if [[ -f /tmp/cpuctl_profile ]] ; then
    :
else
    echo full > /tmp/cpuctl_profile
fi
cur_profile=$(cat /tmp/cpuctl_profile)
case "$cur_profile" in
    idle)
    ;;
    low)
    ;;
    mid)
    ;;
    full)
    ;;
    turbo)
    ;;
    *)
    ;;
esac
}

case "$1" in
    cores)
        cycle_cores "$2"
        ;;
    clock)
        cycle_clock "$2"
        ;;
    governor)
        cycle_governor
        ;;
    profile)
        cycle_profiles
        ;;
esac

governor="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor | sed 's/^./\u&/')"
cur_max_clock="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
plain_clockspeed="$(echo "$cur_max_clock" | sed 's/0//g')"
clock_digit_count="$(expr $(echo "$plain_clockspeed" | wc -m) - 1)"
physical_cores="$(expr \( $(cat /sys/devices/system/cpu/cpu*/online | grep 1 | wc -l) + 1 \) / 2)"
if [[ "$clock_digit_count" > 1 ]] ; then
    pretty_clockspeed=""$(echo "$plain_clockspeed" | sed 's/^./&\./')"GHz"
else
    pretty_clockspeed=""$plain_clockspeed"00MHz"
fi

notify_message="Cores: "$physical_cores" Clock: "$pretty_clockspeed" Governor: "$governor""
echo "$notify_message"
dbus_notify "$notify_message"

