#!/bin/bash
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

# Global variables:
#
# QUIET: If set, debug output is supressed
#

# Echo text to standard error.
#
debug() {
    if [ -z "$QUIET" ]; then
        echo "$@" >&2
    fi
}

error() {
    echo "Error: $@" >&2
}

replace() {
    sed "s#$1#$2#g"
}

# Wrapper for curl: debug and infinite loop control
#
curl() {
    local -a OPTIONS=(--insecure)
    local DRETVAL=0
    test -n "$QUIET" && OPTIONS=(${OPTIONS[@]} "--silent")
    test -n "$INTERFACE" && OPTIONS=(${OPTIONS[@]} "--interface" "$INTERFACE")
    $(type -P curl) "${OPTIONS[@]}" "$@" || DRETVAL=$?
    return $DRETVAL
#    while true; do
#        $(type -P curl) "${OPTIONS[@]}" "$@" || DRETVAL=$?
#        if [ $DRETVAL -eq 6 -o $DRETVAL -eq 7 ]; then
#            local WAIT=60
#            debug "curl failed with non-fatal retcode $DRETVAL"
#            debug "retry after a safety wait ($WAIT seconds)"
#            sleep $WAIT
#            continue
#        else
#            return $DRETVAL
#        fi
#    done
}

# Get first line that matches a regular expression and extract string from it.
#
# $1: POSIX-regexp to filter (get only the first matching line).
# $2: POSIX-regexp to match (use parentheses) on the matched line.
#
parse() {
    local STRING=$(sed -n "/$1/ s/^.*$2.*$/\1/p" | head -n1) &&
        test "$STRING" && echo "$STRING" ||
        { debug "parse failed: /$1/ $2"; return 1; }
}

# Grep first "Location" (of http header)
# stdin: result of curl request (with -i/--include or -H/--dump-header flag)
#
grep_http_header_location() {
    sed -n 's/^[Ll]ocation:[[:space:]]\+\([^ ]*\)/\1/p' | tr -d "\r"
}

# Check if a string ($2) matches a regexp ($1)
# $? is zero on success
#
match() {
    grep -q "$1" <<< "$2"
}

# Check existance of executable in path
#
# $1: Executable to check
check_exec() {
    type -P $1 > /dev/null
}

# Check if function is defined
#
check_function() {
    declare -F "$1" &>/dev/null
}

# Login and return cookies
#
# $1: String 'username:password'
# $2: Postdata string (ex: 'user=\$USER&password=\$PASSWORD')
# $3: URL to post
post_login() {
    AUTH=$1
    POSTDATA=$2
    LOGINURL=$3

    if test "$AUTH"; then
        IFS=":" read USER PASSWORD <<< "$AUTH"
        debug "starting login process: $USER/$(sed 's/./*/g' <<< "$PASSWORD")"
        DATA=$(eval echo $(echo "$POSTDATA" | sed "s/&/\\\\&/g"))
        COOKIES=$(curl -o /dev/null -c - -d "$DATA" "$LOGINURL")
        test "$COOKIES" || { debug "login error"; return 1; }
        echo "$COOKIES"
    fi
}

# Create a tempfile and return path
#
# $1: Suffix
#
create_tempfile() {
    SUFFIX=$1
    FILE="${TMPDIR:-/tmp}/$(basename $0).$$.$RANDOM$SUFFIX"
    : > "$FILE"
    echo "$FILE"
}

# OCR of an image. Write OCRed text to standard input
#
# Standard input: image
# One or two optionnal arguments
ocr() {
    local OPT_CONFIGFILE=$1
    local OPT_VARFILE=$2
    test -z "$OPT_CONFIGFILE" && OPT_VARFILE=''

    # Tesseract somewhat "peculiar" arguments requirement makes impossible
    # to use pipes or process substitution. Create temporal files
    # instead (*sigh*).
    TIFF=$(create_tempfile ".tif")
    TEXT=$(create_tempfile ".txt")
    convert - tif:- > $TIFF
    tesseract $TIFF ${TEXT/%.txt} $OPT_CONFIGFILE $OPT_VARFILE 1>&2 ||
        { rm -f $TIFF $TEXT; return 1; }
    cat $TEXT
    rm -f $TIFF $TEXT
}

# Show help info for options
#
# $1: options
# $2: indent string
debug_options() {
    OPTIONS=$1
    INDENTING=$2
    while read OPTION; do
        test "$OPTION" || continue
        IFS="," read VAR SHORT LONG VALUE HELP <<< "$OPTION"
        STRING="$INDENTING"
        test "$SHORT" && {
            STRING="$STRING-${SHORT%:}"
            test "$VALUE" && STRING="$STRING $VALUE"
        }
        test "$LONG" -a "$SHORT" && STRING="$STRING, "
        test "$LONG" && {
            STRING="$STRING--${LONG%:}"
            test "$VALUE" && STRING="$STRING=$VALUE"
        }
        debug "$STRING: $HELP"
    done <<< "$OPTIONS"
}

get_modules_options() {
    MODULES=$1
    NAME=$2
    for MODULE in $MODULES; do
        get_options_for_module "$MODULE" "$NAME" | while read OPTION; do
            if test "$OPTION"; then echo "!$OPTION"; fi
        done
    done
}

# Return uppercase string
uppercase() {
    tr '[a-z]' '[A-Z]'
}

continue_downloads() {
    MODULE=$1
    VAR="MODULE_$(echo $MODULE | uppercase)_DOWNLOAD_CONTINUE"
    test "${!VAR}" = "yes"
}

get_options_for_module() {
    MODULE=$1
    NAME=$2
    VAR="MODULE_$(echo $MODULE | uppercase)_${NAME}_OPTIONS"
    echo "${!VAR}"
}

# Show usage info for modules
debug_options_for_modules() {
    MODULES=$1
    NAME=$2
    for MODULE in $MODULES; do
        OPTIONS=$(get_options_for_module "$MODULE" "$NAME")
        if test "$OPTIONS"; then
            debug; debug "Options for module <$MODULE>:"; debug
            debug_options "$OPTIONS" "  "
        fi
    done
}

get_field() {
    echo "$2" | while IFS="," read LINE; do
        echo "$LINE" | cut -d"," -f$1
    done
}

quote() {
    for ARG in "$@"; do
        echo -n "$(declare -p ARG | sed "s/^declare -- ARG=//") "
    done | sed "s/ $//"
}

# Straighforward options and arguments processing using getopt style
#
# Example:
#
# $ set -- -a user:password -q arg1 arg2
# $ eval "$(process_options module "
#           AUTH,a:,auth:,USER:PASSWORD,Help for auth
#           QUIET,q,quiet,,Help for quiet" "$@")"
# $ echo "$AUTH / $QUIET / $1 / $2"
# user:password / 1 / arg1 / arg2
#
process_options() {
    local NAME=$1
    local OPTIONS=$2
    shift 2
    # Strip spaces in options
    local OPTIONS=$(grep -v "^[[:space:]]*$" <<< "$OPTIONS" | \
        sed "s/^[[:space:]]*//; s/[[:space:]]$//")
    while read VAR; do
        unset $VAR
    done < <(get_field 1 "$OPTIONS" | sed "s/^!//")
    local ARGUMENTS="$(getopt -o "$(get_field 2 "$OPTIONS")" \
        --long "$(get_field 3 "$OPTIONS")" -n "$NAME" -- "$@")"
    eval set -- "$ARGUMENTS"
    local -a UNUSED_OPTIONS=()
    while true; do
        test "$1" = "--" && { shift; break; }
        while read OPTION; do
            IFS="," read VAR SHORT LONG VALUE HELP <<< "$OPTION"
            UNUSED=0
            if test "${VAR:0:1}" = "!"; then
                UNUSED=1
                VAR=${VAR:1}
            fi
            if test "$1" = "-${SHORT%:}" -o "$1" = "--${LONG%:}"; then
                if test "${SHORT:${#SHORT}-1:1}" = ":" -o \
                        "${LONG:${#LONG}-1:1}" = ":"; then
                    if test "$UNUSED" = 0; then
                        echo "$VAR=$(quote "$2")"
                    else
                        if test "${1:0:2}" = "--"; then
                            UNUSED_OPTIONS=("${UNUSED_OPTIONS[@]}" "$1=$2")
                        else
                            UNUSED_OPTIONS=("${UNUSED_OPTIONS[@]}" "$1" "$2")
                        fi
                    fi
                    shift
                else
                    if test "$UNUSED" = 0; then
                        echo "$VAR=1"
                    else
                        UNUSED_OPTIONS=("${UNUSED_OPTIONS[@]}" "$1")
                    fi
                fi
                break
            fi
        done <<< "$OPTIONS"
        shift
    done
    echo "$(declare -p UNUSED_OPTIONS)"
    echo "set -- $(quote "$@")"
}

# Output image in ascii chars (uses aview)
#
aview_ascii_image() {
  convert $1 -negate pnm:- |
    aview -width 60 -height 28 -kbddriver stdin -driver stdout <(cat) 2>/dev/null <<< "q" |
    awk 'BEGIN { part = 0; }
      /\014/ { part++; next; }
      // { if (part == 2) print $0; }' | \
    grep -v "^[[:space:]]*$"
}

caca_ascii_image() {
    img2txt -W 60 -H 14 $1
}

# $1: image
show_image_and_tee() {
    test -n "$QUIET" && { cat; return; }
    local TEMPIMG=$(create_tempfile)
    cat > $TEMPIMG
    if which aview &>/dev/null; then
        aview_ascii_image $TEMPIMG >&2
    elif which img2txt &>/dev/null; then
        caca_ascii_image $TEMPIMG >&2
    else
        debug "Install aview or libcaca to display captcha image"
    fi
    cat $TEMPIMG
    rm -f $TEMPIMG
}

# Get module name from URL link
#
# $1: URL
get_module() {
    URL=$1
    MODULES=$2
    for MODULE in $MODULES; do
        VAR=MODULE_$(echo $MODULE | uppercase)_REGEXP_URL
        match "${!VAR}" "$URL" && { echo $MODULE; return; } || true
    done
}

timeout_init() {
    PS_TIMEOUT=$1
}

timeout_update() {
    local WAIT=$1
    test -z "$PS_TIMEOUT" && return
    debug "Time left to timeout: $PS_TIMEOUT secs" 
    if test $(expr $PS_TIMEOUT - $WAIT) -lt 0; then
        error "timeout reached (asked $WAIT secs to wait, but remaining time is $PS_TIMEOUT)"
        return 1
    fi
    PS_TIMEOUT=$(expr $PS_TIMEOUT - $WAIT)
}

retry_limit_init() {
    PS_RETRY_LIMIT=$1
}

retry_limit_not_reached() {
    test -z "$PS_RETRY_LIMIT" && return
    debug "Retries left: $PS_RETRY_LIMIT" 
    PS_RETRY_LIMIT=$(expr $PS_RETRY_LIMIT - 1)
    test $PS_RETRY_LIMIT -ge 0
}

# Countdown from VALUE (in UNIT_STR units) in STEP values
#
countdown() {
    local VALUE=$1
    local STEP=$2
    local UNIT_STR=$3
    local UNIT_SECS=$4
    
    local TOTAL_WAIT=$((VALUE * UNIT_SECS))
    timeout_update $TOTAL_WAIT || return 1
   
    for REMAINING in $(seq $VALUE -$STEP 1 2>/dev/null || jot - $VALUE 1 -$STEP); do
        test $REMAINING = $VALUE &&
            debug -n "Waiting $VALUE $UNIT_STR... " || debug -n "$REMAINING.. "
        local WAIT=$((STEP * UNIT_SECS))
        test $STEP -le $REMAINING && sleep $WAIT || sleep $((REMAINING * UNIT_SECS))
    done
    debug 0
}
