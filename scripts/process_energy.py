#!/usr/bin/env python3

import json
import os
import sys
import re
from pathlib import Path
from datetime import datetime

import requests


# ============================================================
# CONFIGURATION
# ============================================================

SERVER_URL = "http://192.168.1.54:8000/result"

JAVA_FILE = Path(
    "/home/carlos/PYPEN_EXECUTION.txt"
)

PERF_FILE = Path(
    "/tmp/wattsci/perf-energy-intervals.txt"
)


# ============================================================
# REGEX FOR PERF ENERGY FILE
# ============================================================

PERF_RE = re.compile(
    r"^\s*"
    r"([0-9]+(?:\.[0-9]+)?)"
    r"\s+"
    r"([0-9]+(?:[.,][0-9]+)?)"
    r"\s+"
    r"Joules\s+"
    r"power/energy-(pkg|cores)/",
    re.IGNORECASE
)


# ============================================================
# PERF START
# ============================================================

def parse_perf_start(path):

    with path.open(
        "r",
        encoding="utf-8",
        errors="replace"
    ) as f:

        for line in f:

            line = line.strip()
            line = line.lstrip("#").strip()

            if line.lower().startswith("started on "):

                date_string = line[
                    len("started on "):
                ]

                date_string = " ".join(
                    date_string.split()
                )

                return datetime.strptime(
                    date_string,
                    "%a %b %d %H:%M:%S %Y"
                )

    raise ValueError(
        f"No se encontró 'started on ...' en {path}"
    )


# ============================================================
# PERF PARSER
# ============================================================

def parse_perf(path):

    samples = {}

    with path.open(
        "r",
        encoding="utf-8",
        errors="replace",
        buffering=1024 * 1024
    ) as f:

        for line in f:

            match = PERF_RE.match(line)

            if not match:
                continue

            time_s = float(
                match.group(1)
            )

            energy = float(
                match.group(2).replace(",", ".")
            )

            kind = match.group(3).lower()

            if time_s not in samples:

                samples[time_s] = {
                    "pkg": 0.0,
                    "cores": 0.0
                }

            if kind == "pkg":

                samples[time_s]["pkg"] = energy

            elif kind == "cores":

                samples[time_s]["cores"] = energy

    ordered = sorted(
        samples.items(),
        key=lambda x: x[0]
    )

    perf_times = []
    pkg_energy = []
    cores_energy = []

    total_pkg = 0.0
    total_cores = 0.0

    for time_s, values in ordered:

        perf_times.append(time_s)

        pkg = values["pkg"]
        cores = values["cores"]

        pkg_energy.append(pkg)
        cores_energy.append(cores)

        total_pkg += pkg
        total_cores += cores

    return (
        perf_times,
        pkg_energy,
        cores_energy,
        total_pkg,
        total_cores,
        len(perf_times)
    )


# ============================================================
# JAVA START
# ============================================================

def parse_java_start(path):

    with path.open(
        "r",
        encoding="utf-8",
        errors="replace"
    ) as f:

        line = f.readline().strip()

    parts = line.split(",")

    if len(parts) != 3:

        raise ValueError(
            "La primera línea de Java debe tener "
            "START,timestamp,systemnano"
        )

    if parts[0].strip() != "START":

        raise ValueError(
            f"La primera línea no es START: {line}"
        )

    timestamp_ms = int(
        parts[1]
    )

    systemnano = int(
        parts[2]
    )

    return (
        timestamp_ms,
        systemnano
    )


# ============================================================
# OFFSET
# ============================================================

def calculate_offset(
    java_timestamp_ms,
    perf_start
):

    java_datetime = datetime.fromtimestamp(
        java_timestamp_ms / 1000.0
    )

    offset = (
        java_datetime - perf_start
    ).total_seconds()

    return (
        offset,
        java_datetime
    )


# ============================================================
# RESULT OBJECTS
# ============================================================

def create_result(
    thread,
    method
):

    return {
        "thread": thread,
        "method": method,
        "invocations": 0,
        "total_duration": 0.0,
        "energy_pkg_j": 0.0,
        "energy_cores_j": 0.0
    }


def create_method_result(
    method
):

    return {
        "method": method,
        "invocations": 0,
        "total_duration": 0.0,
        "energy_pkg_j": 0.0,
        "energy_cores_j": 0.0
    }


# ============================================================
# ENERGY TRACKER
# ============================================================

class EnergyTracker:

    def __init__(
        self,
        perf_times,
        pkg_energy,
        cores_energy
    ):

        self.perf_times = perf_times
        self.pkg_energy = pkg_energy
        self.cores_energy = cores_energy

        self.index = 1

        self.cursor = (
            perf_times[0]
            if perf_times
            else 0.0
        )

        self.cumulative_pkg = 0.0
        self.cumulative_cores = 0.0

    def advance_to(
        self,
        target_time,
        active_count
    ):

        if target_time <= self.cursor:

            return 0.0, 0.0

        if not self.perf_times:

            self.cursor = target_time

            return 0.0, 0.0

        pkg_result = 0.0
        cores_result = 0.0

        if target_time <= self.perf_times[0]:

            self.cursor = target_time

            return 0.0, 0.0

        if self.cursor < self.perf_times[0]:

            self.cursor = self.perf_times[0]

        if self.index >= len(self.perf_times):

            self.cursor = target_time

            return 0.0, 0.0

        while (
            self.index < len(self.perf_times)
            and self.cursor < target_time
        ):

            interval_end = (
                self.perf_times[self.index]
            )

            if self.cursor < interval_end:

                segment_end = min(
                    target_time,
                    interval_end
                )

                segment_duration = (
                    segment_end
                    - self.cursor
                )

                perf_interval_duration = (
                    interval_end
                    - self.perf_times[
                        self.index - 1
                    ]
                )

                if (
                    perf_interval_duration > 0
                    and segment_duration > 0
                    and active_count > 0
                ):

                    pkg_sample = (
                        self.pkg_energy[
                            self.index
                        ]
                    )

                    cores_sample = (
                        self.cores_energy[
                            self.index
                        ]
                    )

                    pkg_power = (
                        pkg_sample
                        / perf_interval_duration
                    )

                    cores_power = (
                        cores_sample
                        / perf_interval_duration
                    )

                    fraction = (
                        segment_duration
                        / active_count
                    )

                    pkg_result += (
                        pkg_power
                        * fraction
                    )

                    cores_result += (
                        cores_power
                        * fraction
                    )

                self.cursor = segment_end

                if self.cursor >= interval_end:

                    self.index += 1

                continue

            self.index += 1

        self.cumulative_pkg += pkg_result
        self.cumulative_cores += cores_result

        return (
            pkg_result,
            cores_result
        )


# ============================================================
# PROCESS JAVA
# ============================================================

def process_java(
    path,
    java_start_nano,
    offset,
    perf_times,
    pkg_energy,
    cores_energy
):

    tracker = EnergyTracker(
        perf_times,
        pkg_energy,
        cores_energy
    )

    stacks = {}
    totals_by_thread = {}

    event_count = 0
    entries = 0
    exits = 0

    matched_exits = 0
    unmatched_exits = 0

    first_perf_time = None
    last_perf_time = None

    active_count = 0
    last_java_time = None

    with path.open(
        "r",
        encoding="utf-8",
        errors="replace",
        buffering=1024 * 1024
    ) as f:

        for line in f:

            if (
                line.startswith("START")
                or line.startswith("THREAD")
                or not line.strip()
            ):
                continue

            parts = line.rstrip(
                "\r\n"
            ).split(",", 3)

            if len(parts) != 4:
                continue

            thread = parts[0]

            try:

                systemnano = int(
                    parts[1]
                )

            except ValueError:

                continue

            method = parts[2]
            action = parts[3].strip()

            if action not in ("I", "O"):
                continue

            event_count += 1

            perf_time = (
                offset
                + (
                    systemnano
                    - java_start_nano
                ) * 1e-9
            )

            if (
                last_java_time is not None
                and perf_time < last_java_time
            ):

                raise ValueError(
                    "Los eventos Java no están "
                    "ordenados cronológicamente."
                )

            last_java_time = perf_time

            if first_perf_time is None:
                first_perf_time = perf_time

            last_perf_time = perf_time

            tracker.advance_to(
                perf_time,
                active_count
            )

            if action == "I":

                entries += 1

                stack = stacks.get(
                    thread
                )

                if stack is None:

                    stack = []
                    stacks[thread] = stack

                stack.append(
                    (
                        method,
                        perf_time,
                        systemnano,
                        tracker.cumulative_pkg,
                        tracker.cumulative_cores
                    )
                )

                active_count += 1

                continue

            exits += 1

            stack = stacks.get(
                thread
            )

            if not stack:

                unmatched_exits += 1
                continue

            (
                method_i,
                start,
                start_nano,
                pkg_start,
                cores_start
            ) = stack[-1]

            if method_i == method:

                stack.pop()

            else:

                found = None

                for i in range(
                    len(stack) - 1,
                    -1,
                    -1
                ):

                    if stack[i][0] == method:

                        found = i
                        break

                if found is None:

                    unmatched_exits += 1
                    continue

                (
                    method_i,
                    start,
                    start_nano,
                    pkg_start,
                    cores_start
                ) = stack.pop(found)

            matched_exits += 1

            active_count -= 1

            if active_count < 0:
                active_count = 0

            end = perf_time

            duration = (
                end - start
            )

            if duration < 0:
                continue

            pkg = (
                tracker.cumulative_pkg
                - pkg_start
            )

            cores = (
                tracker.cumulative_cores
                - cores_start
            )

            if pkg < 0:
                pkg = 0.0

            if cores < 0:
                cores = 0.0

            key = (
                thread,
                method_i
            )

            result = totals_by_thread.get(
                key
            )

            if result is None:

                result = create_result(
                    thread,
                    method_i
                )

                totals_by_thread[key] = result

            result["invocations"] += 1
            result["total_duration"] += duration
            result["energy_pkg_j"] += pkg
            result["energy_cores_j"] += cores

    return {
        "totals_by_thread": totals_by_thread,
        "event_count": event_count,
        "entries": entries,
        "exits": exits,
        "matched_exits": matched_exits,
        "unmatched_exits": unmatched_exits,
        "first_perf_time": first_perf_time,
        "last_perf_time": last_perf_time,
        "allocated_pkg": tracker.cumulative_pkg,
        "allocated_cores": tracker.cumulative_cores
    }


# ============================================================
# AGGREGATE METHODS
# ============================================================

def aggregate_methods(
    totals_by_thread
):

    methods = {}

    for result in totals_by_thread.values():

        method = result["method"]

        aggregated = methods.get(
            method
        )

        if aggregated is None:

            aggregated = create_method_result(
                method
            )

            methods[method] = aggregated

        aggregated["invocations"] += (
            result["invocations"]
        )

        aggregated["total_duration"] += (
            result["total_duration"]
        )

        aggregated["energy_pkg_j"] += (
            result["energy_pkg_j"]
        )

        aggregated["energy_cores_j"] += (
            result["energy_cores_j"]
        )

    return list(
        methods.values()
    )


# ============================================================
# SORT METHODS
# ============================================================

def sort_methods(
    methods
):

    return sorted(
        methods,
        key=lambda x: (
            -x["energy_pkg_j"],
            -x["total_duration"],
            x["method"]
        )
    )


def sort_methods_by_thread(
    methods
):

    return sorted(
        methods,
        key=lambda x: (
            x["thread"],
            -x["energy_pkg_j"],
            -x["total_duration"],
            x["method"]
        )
    )


# ============================================================
# ROUND NUMBERS
# ============================================================

def round_numbers(
    value
):

    if isinstance(value, dict):

        return {
            key: round_numbers(val)
            for key, val in value.items()
        }

    if isinstance(value, list):

        return [
            round_numbers(val)
            for val in value
        ]

    if isinstance(value, float):

        return round(
            value,
            9
        )

    return value


# ============================================================
# PROCESS FILES
# ============================================================

def process_files(
    java_file,
    perf_file
):

    print("[INFO] Reading perf")

    perf_start = parse_perf_start(
        perf_file
    )

    (
        perf_times,
        pkg_energy,
        cores_energy,
        total_pkg,
        total_cores,
        perf_count
    ) = parse_perf(
        perf_file
    )

    if perf_count == 0:

        raise ValueError(
            "No se encontraron muestras de energía."
        )

    print(
        f"[OK] Perf samples: {perf_count:,}"
    )

    print(
        f"[OK] Total pkg: {total_pkg:.6f} J"
    )

    print(
        f"[OK] Total cores: {total_cores:.6f} J"
    )

    print("[INFO] Reading Java START")

    (
        java_timestamp_ms,
        java_start_nano
    ) = parse_java_start(
        java_file
    )

    (
        offset,
        java_datetime
    ) = calculate_offset(
        java_timestamp_ms,
        perf_start
    )

    print(
        f"[OK] Offset: {offset:.9f} s"
    )

    print("[INFO] Processing Java")

    processed = process_java(
        java_file,
        java_start_nano,
        offset,
        perf_times,
        pkg_energy,
        cores_energy
    )

    totals_by_thread = (
        processed["totals_by_thread"]
    )

    methods = aggregate_methods(
        totals_by_thread
    )

    methods_by_thread = list(
        totals_by_thread.values()
    )

    methods = sort_methods(
        methods
    )

    methods_by_thread = sort_methods_by_thread(
        methods_by_thread
    )

    print(
        f"[OK] Events: {processed['event_count']:,}"
    )

    print(
        f"[OK] Invocations: "
        f"{processed['matched_exits']:,}"
    )

    print(
        f"[OK] Unique methods: {len(methods):,}"
    )

    first_time = (
        processed["first_perf_time"]
    )

    last_time = (
        processed["last_perf_time"]
    )

    if (
        first_time is not None
        and last_time is not None
    ):

        global_duration = (
            last_time - first_time
        )

    else:

        global_duration = (
            perf_times[-1]
            - perf_times[0]
        )

    result = {

        "metadata": {

            "perf_start":
                str(perf_start),

            "java_timestamp_ms":
                java_timestamp_ms,

            "java_start_datetime":
                str(java_datetime),

            "java_start_systemnano":
                java_start_nano,

            "offset_java_to_perf_seconds":
                offset,

            "perf_samples":
                perf_count,

            "java_events":
                processed["event_count"],

            "entries":
                processed["entries"],

            "exits":
                processed["exits"],

            "matched_exits":
                processed["matched_exits"],

            "unmatched_exits":
                processed["unmatched_exits"],

            "unique_methods":
                len(methods),

            "thread_method_combinations":
                len(methods_by_thread)
        },

        "global": {

            "invocations":
                processed["matched_exits"],

            "total_duration":
                global_duration,

            "energy_pkg_j":
                total_pkg,

            "energy_cores_j":
                total_cores
        },

        "energy_allocation": {

            "measured_pkg_j":
                total_pkg,

            "measured_cores_j":
                total_cores,

            "allocated_pkg_j":
                processed["allocated_pkg"],

            "allocated_cores_j":
                processed["allocated_cores"],

            "unallocated_pkg_j":
                total_pkg
                - processed["allocated_pkg"],

            "unallocated_cores_j":
                total_cores
                - processed["allocated_cores"]
        },

        "methods":
            methods,

        "methods_by_thread":
            methods_by_thread
    }

    return round_numbers(
        result
    )


# ============================================================
# SEND RESULT TO SERVER
# ============================================================

def send_result(
    result
):

    print(
        f"[INFO] Sending result to {SERVER_URL}"
    )

    response = requests.post(
        SERVER_URL,
        json=result,
        timeout=300
    )

    response.raise_for_status()

    return response.json()


# ============================================================
# MAIN
# ============================================================

def main():

    print(
        "========================================"
    )

    print(
        "      JAVA ENERGY PROCESSOR"
    )

    print(
        "========================================"
    )

    # --------------------------------------------------------
    # CHECK FILES
    # --------------------------------------------------------

    if not JAVA_FILE.exists():

        print(
            f"[ERROR] File not found: {JAVA_FILE}"
        )

        sys.exit(1)

    if not PERF_FILE.exists():

        print(
            f"[ERROR] File not found: {PERF_FILE}"
        )

        sys.exit(1)

    print(
        f"[INFO] Java file: {JAVA_FILE}"
    )

    print(
        f"[INFO] Perf file: {PERF_FILE}"
    )

    # --------------------------------------------------------
    # PROCESS
    # --------------------------------------------------------

    try:

        result = process_files(
            JAVA_FILE,
            PERF_FILE
        )

        # ----------------------------------------------------
        # EXECUTION METADATA
        # ----------------------------------------------------

        result["execution"] = {

            "CI":
                os.getenv(
                    "CI",
                    ""
                ),

            "RUN_ID":
                os.getenv(
                    "RUN_ID",
                    ""
                ),

            "REF_NAME":
                os.getenv(
                    "REF_NAME",
                    ""
                ),

            "REPOSITORY":
                os.getenv(
                    "REPOSITORY",
                    ""
                ),

            "WORKFLOW_ID":
                os.getenv(
                    "WORKFLOW_ID",
                    ""
                ),

            "WORKFLOW_NAME":
                os.getenv(
                    "WORKFLOW_NAME",
                    ""
                ),

            "COMMIT_HASH":
                os.getenv(
                    "COMMIT_HASH",
                    ""
                )
        }

        # ----------------------------------------------------
        # SEND JSON ONLY
        # ----------------------------------------------------

        server_response = send_result(
            result
        )

        print(
            "[OK] Server response:"
        )

        print(
            json.dumps(
                server_response,
                indent=2,
                ensure_ascii=False
            )
        )

    except requests.RequestException as e:

        print(
            f"[ERROR] Server request failed: {e}"
        )

        sys.exit(1)

    except Exception as e:

        print(
            f"[ERROR] {type(e).__name__}: {e}"
        )

        sys.exit(1)


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":

    main()
