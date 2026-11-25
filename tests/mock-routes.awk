# A small IPv4 FIB for ip -batch in the routing tests. Routes with the same
# destination and different metrics coexist, including prohibit fallbacks.
function route_key(line, fields, count, prefix, metric, i) {
    count = split(line, fields, " ")
    prefix = fields[1]
    if (prefix == "prohibit" || prefix == "throw") prefix = fields[2]
    sub(/\/32$/, "", prefix)
    metric = 0
    for (i = 1; i < count; i++) if (fields[i] == "metric") metric = fields[i+1]
    return prefix SUBSEP metric
}
function load_table(table, file, line) {
    if (table in loaded) return
    file = root "/routes" table
    while ((getline line < file) > 0) routes[table SUBSEP route_key(line)] = line
    close(file)
    loaded[table] = 1
}
{
    if ($1 != "route" || $(NF-1) != "table" || $NF !~ /^[0-9]+$/) exit 1
    table = $NF
    load_table(table)
    if ($2 == "flush") {
        for (key in routes) if (index(key, table SUBSEP) == 1) delete routes[key]
    } else {
        line = $3
        for (i = 4; i <= NF-2; i++) line = line " " $i
        sub(/\/32( |$)/, " ", line)
        sub(/ $/, "", line)
        key = table SUBSEP route_key(line)
        if ($2 == "del") {
            if (!(key in routes)) exit 1
            delete routes[key]
        } else if ($2 == "replace" || ($2 == "add" && !(key in routes))) {
            routes[key] = line
        } else exit 1
    }
    if (fail_after && NR == fail_after) exit 1
}
END {
    for (table in loaded) {
        file = root "/routes" table
        printf "%s", "" > file
        for (key in routes) if (index(key, table SUBSEP) == 1) print routes[key] > file
        close(file)
    }
}
