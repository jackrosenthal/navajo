#!/bin/bash
# BashNET Navajo: Advanced HTTP Server written in Bash
# Author: Jack Rosenthal
export BASHNET_PRODUCT="BashNET Navajo"
export BASHNET_PRODUCT_SHORT="Navajo"
export BASHNET_MAINTAINER="Jack Rosenthal <jack@rosenth.al>"
export NAVAJO_VERSION=0.0.1

# Load the config, if any
for d in /etc /etc/navajo .; do
    [[ -f "$d/navajoconf.sh" ]] && source "$d/navajoconf.sh"
done

# default options
if [[ $UID -eq 0 ]]; then
    DEFAULT_HTTP_PORT=80
    DEFAULT_HTTPS_PORT=443
else
    DEFAULT_HTTP_PORT=8080
    DEFAULT_HTTPS_PORT=8443
fi

: ${HTTP_PORT:=$DEFAULT_HTTP_PORT}
: ${HTTPS_PORT:=$DEFAULT_HTTPS_PORT}
: ${HTTP_REDIR_HTTPS:=false}
: ${HTTP_PROCS:=1}
: ${HTTPS_PROCS:=0}
: ${WEBROOT:="$PWD"}
WEBROOT="$(realpath $WEBROOT)"
: ${DIRBROWSE:=true}
: ${CGI_ENABLE:=false}
: ${CGI_PATH:=/cgi-bin}
: ${CGI_DIR:="$WEBROOT/cgi-bin"}
: ${FIFO_DIR:=/tmp}
: ${SERVER_NAME:="$BASHNET_PRODUCT_SHORT/$NAVAJO_VERSION"}
: ${INDEX_FILES:="index.html index.htm"}

for c in ncat nc netcat; do
    if command -v "$c" >/dev/null; then
        : ${NETCAT:=$c}
    fi
done

echo "Welcome to $BASHNET_PRODUCT!" >&2
echo "Please report bugs to $BASHNET_MAINTAINER." >&2
echo >&2

if [[ -z "$NETCAT" ]]; then
    echo -e "\e[31m\e[1mFATAL:\e[21m $BASHNET_PRODUCT requires netcat!" >&2
    echo -e "If you have netcat but it is not in your PATH, specify NETCAT in your config.\e[0m" >&2
    exit 1
fi

declare -A responses
responses[200]="OK"
responses[201]="Created"
responses[202]="Accepted"
responses[203]="Non-Authoritative Information"
responses[204]="No Content"
responses[205]="Reset Content"
responses[206]="Partial Content"
responses[300]="Multiple Choices"
responses[301]="Moved Permanently"
responses[302]="Found"
responses[303]="See Other"
responses[304]="Not Modified"
responses[305]="Use Proxy"
responses[307]="Temporary Redirect"
responses[308]="Permanent Redirect"
responses[400]="Bad Request"
responses[401]="Unauthorized"
responses[403]="Forbidden"
responses[404]="Not Found"
responses[405]="Method Not Allowed"
responses[406]="Not Acceptable"
responses[407]="Proxy Authentication Required"
responses[408]="Request Timeout"
responses[409]="Conflict"
responses[410]="Gone"
responses[411]="Length Required"
responses[412]="Precondition Failed"
responses[413]="Payload Too Large"
responses[414]="URI Too Long"
responses[415]="Unsupported Media Type"
responses[416]="Range Not Satisfiable"
responses[417]="Expectation Failed"
responses[421]="Misdirected Request"
responses[426]="Upgrade Required"
responses[429]="Too Many Requests"
responses[431]="Request Header Fields Too Large"
responses[500]="Internal Server Error"
responses[501]="Not Implemented"
responses[502]="Bad Gateway"
responses[503]="Service Unavailable"
responses[504]="Gateway Timeout"
responses[505]="HTTP Version Not Supported"
responses[506]="Variant Also Negotiates"
responses[507]="Insufficent Storage"
responses[508]="Loop Detected"
responses[510]="Not Extended"
responses[511]="Network Authentication Required"

declare -A taunts
taunts[400]="$BASHNET_PRODUCT seems to think that the request your browser made is absolute garbage."
taunts[401]="It was worth a shot."
taunts[403]="Did someone tell you that you were SUPPOSED to be here?"
taunts[404]="Hang up and try your call again. Dial carefully next time."
taunts[405]="The method you are trying to use is not allowed in this part of town."
taunts[410]="It was here. It is now gone. We know."
taunts[500]="This one was my fault. I'm sorry."
taunts[501]="As you know, the developers of $BASHNET_PRODUCT are very lazy. They did not implement what you wanted. Tough luck."
taunts[505]="You are too hipster for $BASHNET_PRODUCT."

error_page () {
    if [[ $1 -lt 400 ]]; then
        return
    fi
    cat <<EOF
<HTML>
<HEAD>
<TITLE>$1 Error</TITLE>
</HEAD>
<BODY>
<H1>Error ${1}: ${responses[$1]}</H1>
<P>${taunts[$1]}</P>
<EM>$SERVER_NAME</EM>
</BODY>
</HTML>
EOF
}

serve_http_proc () {
    local thread_id=$1 i=0 fifo
    while true; do
        fifo="${FIFO_DIR}/navajo-fifo-$USER-${thread_id}-${i}"
        rm -f $fifo
        mkfifo $fifo
        cat $fifo | stripcr | handle_request | $NETCAT -lp $HTTP_PORT >$fifo
        rm -f $fifo
        i=$((i+1))
    done
}

handle_request () {
    local line
    while read line; do
        # Empty Lines! NOM NOM!
        echo "$line" | grep "^\s*$" >/dev/null || break
    done

    declare -A headers=()
    local method path httpver
    read method path httpver <<<"$line"

    # Pretty log!
    if ! [[ "$method" =~ ^(HEAD|GET|POST|PUT|OPTIONS|DELETE)$ ]]; then
        echo -e "\e[31m\e[1mERR:\e[21m Bad request "$line"\e[0m" >&2
        dump_headers 400
        return
    elif ! [[ "$httpver" == HTTP/1.[01] ]]; then
        echo -e "\e[31m\e[1mERR:\e[21m Unsupported HTTP Version "$httpver"\e[0m" >&2
        dump_headers 505
        return
    else
        echo -e "\e[93m\e[1m$method\e[0m \e[92m$path\e[0m" >&2
    fi

    # URL Decode the REQUEST URI
    path="$(urldecode "$path")"

    # Consume the headers!
    while read hline; do
        echo "$hline" | grep "^\s*$" >/dev/null && break
        local a b
        read a b <<<"$hline"
        headers["$(header_case $a)"]="$b"
    done

    # Is there a query string? We can eat this at this point
    local QUERY_STRING=""
    local REQUEST_URI="$path"
    if [[ "$path" =~ .*\?.* ]]; then
        QUERY_STRING="$(echo "$path" | cut -d'?' -f 2-)"
        path="$(echo "$path" | cut -d'?' -f1)"
    fi

    # Is it a directory? If so, let's try and find default names.
    local changed=false
    if [[ -d "$WEBROOT/$path" ]]; then
        local n
        for n in $INDEX_FILES; do
            if [[ -f "$WEBROOT/$path/$n" ]]; then
                path="${path%/}/$n"
                changed=true
                break
            fi
        done
    fi

    if $changed; then
        echo -e "  \e[34m--> Using index file $path\e[0m" >&2
    fi

    # Detect local file inclusion hax
    if ! [[ "$(realpath "$WEBROOT/$path" 2>/dev/null || echo "$WEBROOT")" =~ ^"$WEBROOT".*$ ]]; then
        echo -e "  \e[34m--> Outside my webroot? I'm playing this one safe!\e[0m" >&2
        dump_headers 403
        return
    fi

    # Handle the request!
    case "$method" in
        HEAD )
            dump_headers
            ;;
        GET )
            dump_headers
            dump_contents
            ;;
        POST )
            dump_headers 501
            ;;
        PUT )
            dump_headers 501
            ;;
        OPTIONS )
            dump_headers 501
            ;;
        DELETE )
            dump_headers 501
            ;;
    esac
}

dump_contents () {
    if [[ -f "$WEBROOT/$path" ]]; then
        cat "$WEBROOT/$path"
    elif [[ -d "$WEBROOT/$path" ]] && $DIRBROWSE; then
        dirbrowse
    fi
}

header_case () {
    local last="-" i
    for (( i=0; i < ${#1}; i++ )); do
        if [[ "${1:$i:1}" == ":" ]]; then
            # Hmmm... looks like that's it!
            break
        elif [[ "$last" == "-" ]]; then
            echo -n ${1:$i:1} | tr '[a-z]' '[A-Z]'
        else
            echo -n ${1:$i:1} | tr '[A-Z]' '[a-z]'
        fi
        last=${1:$i:1}
    done
    echo
}

dump_headers () {
    local RESPONSE
    if [[ $# -eq 1 ]]; then
        # We were given a special response already
        RESPONSE=$1
        echo -e "  \e[34m--> ${responses[$1]}\e[0m" >&2
    elif ! [[ -e "$WEBROOT/$path" ]]; then
        # Oh noes! 404 not found!
        RESPONSE=404
        echo -e "  \e[34m--> File not found\e[0m" >&2
    elif ! [[ -r "$WEBROOT/$path" ]]; then
        # Well, it's here, too bad the server cannot read it
        RESPONSE=403
        echo -e "  \e[34m--> Cannot read file\e[0m" >&2
    elif [[ -d "$WEBROOT/$path" ]] && ! $DIRBROWSE; then
        # Itsa directory, but directory browsing is disabled
        RESPONSE=403
        echo -e "  \e[34m--> Directory browsing disabled\e[0m" >&2
    else
        # All else is OK, we should be OK to handle the request
        RESPONSE=200
    fi

    echo "HTTP/1.1 $RESPONSE ${responses[$RESPONSE]}"
    echo "Date: $(date -Ru)"
    echo "Content-Type: $(mime_type "$WEBROOT/$path")"
    echo "Server: $SERVER_NAME"
    echo "Last-Modified: $(date -Ru)"
    echo "Connection: close"
    echo
    error_page $RESPONSE
}

mime_type () {
    if [[ -f "$1" ]]; then
        file -i -b "$1"
    else
        echo "text/html"
    fi
}

stripcr () {
    while read line; do
        if [[ "${line:$((${#line}-1)):1}" == "" ]]; then
            echo "${line:0:$((${#line}-1))}"
        else
            echo "$line"
        fi
    done
}

urldecode () {
    echo "$1"
}

dirbrowse () {
    local fn
    echo "<HTML>"
    echo "<HEAD><TITLE>Directory Listing for $path</TITLE></HEAD>"
    echo "<BODY><h1>Directory Listing for $path</h1><ul>"
    ls -1a "$WEBROOT/$path" | while read fn; do
        echo "<li><a href="${path%/}/$fn">$fn</a></li>"
    done
    echo "</ul><em>$SERVER_NAME</em></BODY></HTML>"
}

for (( p=0; p < $HTTP_PROCS; p++ )); do
    serve_http_proc $p &
done

for pid in $(jobs -p); do
    wait $pid
done
