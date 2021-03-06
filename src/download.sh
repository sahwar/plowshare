#!/usr/bin/env bash
#
# Download files from file sharing websites
# Copyright (c) 2010-2013 Plowshare team
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

declare -r VERSION='GIT-snapshot'

declare -r EARLY_OPTIONS="
HELP,h,help,,Show help info
HELPFULL,H,longhelp,,Exhaustive help info (with modules command-line options)
GETVERSION,,version,,Return plowdown version
EXT_PLOWSHARERC,,plowsharerc,f=FILE,Force using an alternate configuration file (overrides default search path)
NO_PLOWSHARERC,,no-plowsharerc,,Do not use any plowshare.conf configuration file"

declare -r MAIN_OPTIONS="
VERBOSE,v,verbose,V=LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
CHECK_LINK,c,check-link,,DEPRECATED option, use plowprobe
MARK_DOWN,m,mark-downloaded,,Mark downloaded links (useful for file list arguments)
NOOVERWRITE,x,no-overwrite,,Do not overwrite existing files
OUTPUT_DIR,o,output-directory,D=DIR,Directory where files will be saved
TEMP_DIR,,temp-directory,D=DIR,Directory for temporary files (final link download, cookies, images)
TEMP_RENAME,,temp-rename,,Append .part suffix to filename while file is being downloaded
MAX_LIMIT_RATE,,max-rate,r=SPEED,Limit maximum speed to bytes/sec (accept usual suffixes)
INTERFACE,i,interface,s=IFACE,Force IFACE network interface
TIMEOUT,t,timeout,n=SECS,Timeout after SECS seconds of waits
MAXRETRIES,r,max-retries,N=NUM,Set maximum retries for download failures (captcha, network errors). Default is 2 (3 tries).
CAPTCHA_METHOD,,captchamethod,s=METHOD,Force specific captcha solving method. Available: online, imgur, x11, fb, nox, none.
CAPTCHA_PROGRAM,,captchaprogram,F=PROGRAM,Call external program/script for captcha solving.
CAPTCHA_9KWEU,,9kweu,s=KEY,9kw.eu captcha (API) key
CAPTCHA_ANTIGATE,,antigate,s=KEY,Antigate.com captcha key
CAPTCHA_BHOOD,,captchabhood,a=USER:PASSWD,CaptchaBrotherhood account
CAPTCHA_DEATHBY,,deathbycaptcha,a=USER:PASSWD,DeathByCaptcha account
GLOBAL_COOKIES,,cookies,f=FILE,Force using specified cookies file
GET_MODULE,,get-module,,Don't process initial link, echo module name only and return
PRE_COMMAND,,run-before,F=PROGRAM,Call external program/script before new link processing
POST_COMMAND,,run-after,F=PROGRAM,Call external program/script after link being successfully processed
SKIP_FINAL,,skip-final,,Don't process final link (returned by module), just skip it (for each link)
PRINTF_FORMAT,,printf,s=FORMAT,Print results in a given format (for each successful download). Default string is: \"%F\".
NO_MODULE_FALLBACK,,fallback,,If no module is found for link, simply download it (HTTP GET)
NO_CURLRC,,no-curlrc,,Do not use curlrc config file"


# Translate to absolute path (like GNU "readlink -f")
# $1: script path (usually a symlink)
# Note: If '-P' flags (of cd) are removed, directory symlinks
# won't be translated (but results are correct too).
absolute_path() {
    local SAVED_PWD=$PWD
    local TARGET=$1

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
        DIR=$PWD
    done

    if [ -f "$TARGET" ]; then
        DIR=$(dirname "$TARGET")
    else
        DIR=$TARGET
    fi

    cd -P "$DIR"
    TARGET=$PWD
    cd "$SAVED_PWD"
    echo "$TARGET"
}

# Guess if item is a generic URL (a simple link string) or a text file with links.
# $1: single URL or file (containing links)
process_item() {
    local -r ITEM=$1

    if match_remote_url "$ITEM"; then
        echo 'url'
        strip <<< "$ITEM"
    elif [ -f "$ITEM" ]; then
        if [[ $ITEM =~ (zip|rar|tar|[7gx]z|bz2|mp[234g]|avi|mkv|jpg)$ ]]; then
            log_error "Skip: '$ITEM' seems to be a binary file, not a list of links"
        else
            # Discard empty lines and comments
            echo 'file'
            sed -ne '/^[[:space:]]*[^#[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p}' "$ITEM"
        fi
    else
        log_error "Skip: cannot stat '$ITEM': No such file or directory"
    fi
}

# Print usage (on stdout)
# Note: $MODULES is a multi-line list
usage() {
    echo 'Usage: plowdown [OPTIONS] [MODULE_OPTIONS] URL|FILE [URL|FILE ...]'
    echo
    echo '  Download files from file sharing servers.'
    echo '  Available modules:' $MODULES
    echo
    echo 'Global options:'
    echo
    print_options "$EARLY_OPTIONS$MAIN_OPTIONS"
    test -z "$1" || print_module_options "$MODULES" DOWNLOAD
}

# Mark status of link (inside file or to stdout). See --mark-downloaded switch.
# $1: type ("file" or "url" string)
# $2: mark link (boolean) flag
# $3: if type="file": list file (containing URLs)
# $4: raw URL
# $5: status string (OK, PASSWORD, NOPERM, NOTFOUND, NOMODULE)
# $6: filename (can be non empty if not available)
mark_queue() {
    local -r FILE=$3
    local -r URL=$4
    local -r STATUS="#$5"
    local -r FILENAME=${6:+"# $6"}

    if [ -n "$2" ]; then
        if [ 'file' = "$1" ]; then
            if test -w "$FILE"; then
                local -r D=$'\001' # sed separator
                sed -i -e "s$D^[[:space:]]*\(${URL//\\/\\\\/}[[:space:]]*\)\$$D${FILENAME//&/\\&}\n$STATUS \1$D" "$FILE" &&
                    log_notice "link marked in file \`$FILE' ($STATUS)" ||
                    log_error "failed marking link in file \`$FILE' ($STATUS)"
            else
                log_error "Can't mark link, no write permission ($FILE)"
            fi
        else
            test "$FILENAME" && echo "$FILENAME"
            echo "$STATUS $URL"
        fi
    fi
}

# Create an alternative filename
# Pattern is filename.1
#
# $1: filename (with or without path)
# stdout: non existing filename
create_alt_filename() {
    local -r FILENAME=$1
    local -i COUNT=1

    while (( COUNT < 100 )); do
        [ -f "$FILENAME.$COUNT" ] || break
        (( ++COUNT ))
    done
    echo "$FILENAME.$COUNT"
}

# Example: "MODULE_RYUSHARE_DOWNLOAD_RESUME=no"
# $1: module name
module_config_resume() {
    local -u VAR="MODULE_${1}_DOWNLOAD_RESUME"
    test "${!VAR}" = 'yes'
}

# Example: "MODULE_RYUSHARE_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no"
# $1: module name
module_config_need_cookie() {
    local -u VAR="MODULE_${1}_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE"
    test "${!VAR}" = 'yes'
}

# Example: "MODULE_RYUSHARE_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA=(-F "key=value")
# $1: module name
# stdout: variable array name (not content)
module_config_need_extra() {
    local -u VAR="MODULE_${1}_DOWNLOAD_FINAL_LINK_NEEDS_EXTRA"
    test -z "${!VAR}" || echo "${VAR}"
}

# Example: "MODULE_RYUSHARE_DOWNLOAD_SUCCESSIVE_INTERVAL=10"
# $1: module name
module_config_wait() {
    local -u VAR="MODULE_${1}_DOWNLOAD_SUCCESSIVE_INTERVAL"
    echo $((${!VAR}))
}

# Fake download module function. See --fallback switch.
# $1: cookie file (unused here)
# $2: unknown url
# stdout: $2
module_null_download() {
    echo "$2"
}

# Note: Global options $INDEX, $CHECK_LINK, $MARK_DOWN, $NOOVERWRITE,
# $TIMEOUT, $CAPTCHA_METHOD, $GLOBAL_COOKIES, $PRINTF_FORMAT,
# $SKIP_FINAL, $PRE_COMMAND, $POST_COMMAND, $TEMP_RENAME are accessed directly.
download() {
    local -r MODULE=$1
    local -r URL_RAW=$2
    local -r TYPE=$3
    local -r ITEM=$4
    local -r OUT_DIR=$5
    local -r TMP_DIR=$6
    local -r MAX_RETRIES=$7
    local -r LAST_HOST=$8

    local DRETVAL DRESULT AWAIT FILE_NAME FILE_URL COOKIE_FILE COOKIE_JAR ANAME
    local -i STATUS
    local URL_ENCODED=$(uri_encode <<< "$URL_RAW")
    local FUNCTION=${MODULE}_download

    log_notice "Starting download ($MODULE): $URL_ENCODED"
    timeout_init $TIMEOUT

    AWAIT=$(module_config_wait "$MODULE")
    if [[ $AWAIT -gt 0 && $URL = $LAST_HOST* && -z "$CHECK_LINK" && -z "$SKIP_FINAL" ]]; then
        log_notice 'Same previous hoster, forced wait requested'
        wait $AWAIT || {
            log_error "Delay limit reached (${FUNCTION})";
            return $ERR_MAX_WAIT_REACHED;
        }
    fi

    while :; do
        COOKIE_FILE=$(create_tempfile)

        # Use provided cookie
        if [ -s "$GLOBAL_COOKIES" ]; then
            cat "$GLOBAL_COOKIES" > "$COOKIE_FILE"
        fi

        # Pre-processing script
        if [ -n "$PRE_COMMAND" ]; then
            DRETVAL=0
            $(exec "$PRE_COMMAND" "$MODULE" "$URL_ENCODED" "$COOKIE_FILE" >/dev/null) || DRETVAL=$?

            if [ $DRETVAL -eq $ERR_NOMODULE ]; then
                log_notice "Skipping link (as requested): $URL_ENCODED"
                rm -f "$COOKIE_FILE"
                return $ERR_NOMODULE
            elif [ $DRETVAL -ne 0 ]; then
                log_error "Pre-processing script exited with status $DRETVAL, continue anyway"
            fi
        fi

        if test -z "$CHECK_LINK"; then
            local -i TRY=0
            DRESULT=$(create_tempfile) || return

            while :; do
                DRETVAL=0
                $FUNCTION "$COOKIE_FILE" "$URL_ENCODED" >"$DRESULT" || DRETVAL=$?

                if [ $DRETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
                    read AWAIT <"$DRESULT"
                    if [ -z "$AWAIT" ]; then
                        log_debug 'arbitrary wait'
                    else
                        log_debug 'arbitrary wait (from module)'
                    fi
                    wait ${AWAIT:-60} || { DRETVAL=$?; break; }
                    continue
                elif [[ $MAX_RETRIES -eq 0 ]]; then
                    break
                elif [ $DRETVAL -ne $ERR_NETWORK -a \
                       $DRETVAL -ne $ERR_CAPTCHA ]; then
                    break
                # Special case
                elif [ $DRETVAL -eq $ERR_CAPTCHA -a \
                        "$CAPTCHA_METHOD" = 'none' ]; then
                    log_debug 'captcha method set to none, abort'
                    break
                elif (( MAX_RETRIES < ++TRY )); then
                    DRETVAL=$ERR_MAX_TRIES_REACHED
                    break
                fi

                log_notice "Starting download ($MODULE): retry $TRY/$MAX_RETRIES"
            done

            if [ $DRETVAL -eq 0 ]; then
                { read FILE_URL; read FILE_NAME; } <"$DRESULT" || true
            fi

            # Important: keep cookies in a variable and not in a file
            COOKIE_JAR=$(cat "$COOKIE_FILE")
            rm -f "$DRESULT" "$COOKIE_FILE"
        else
            # This code will be removed soon. Use plowprobe instead.
            DRETVAL=0
            $FUNCTION "$COOKIE_FILE" "$URL_ENCODED" >/dev/null || DRETVAL=$?
            rm -f "$COOKIE_FILE"

            if [ $DRETVAL -eq 0 -o \
                    $DRETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE -o \
                    $DRETVAL -eq $ERR_LINK_NEED_PERMISSIONS -o \
                    $DRETVAL -eq $ERR_LINK_PASSWORD_REQUIRED ]; then
                log_notice "Link active: $URL_ENCODED"
                echo "$URL_ENCODED"
                return 0
            fi
        fi

        case $DRETVAL in
            0)
                ;;
            $ERR_LOGIN_FAILED)
                log_error 'Login process failed. Bad username/password or unexpected content'
                return $DRETVAL
                ;;
            $ERR_LINK_TEMP_UNAVAILABLE)
                log_error 'File link is alive but not currently available, try later'
                return $DRETVAL
                ;;
            $ERR_LINK_PASSWORD_REQUIRED)
                log_error 'You must provide a valid password'
                mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" PASSWORD
                return $DRETVAL
                ;;
            $ERR_LINK_NEED_PERMISSIONS)
                log_error 'Insufficient permissions (private/premium link)'
                mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" NOPERM
                return $DRETVAL
                ;;
            $ERR_SIZE_LIMIT_EXCEEDED)
                log_error 'Insufficient permissions (file size limit exceeded)'
                return $DRETVAL
                ;;
            $ERR_LINK_DEAD)
                log_error 'Link is not alive: file not found'
                mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" NOTFOUND
                return $DRETVAL
                ;;
            $ERR_MAX_WAIT_REACHED)
                log_error "Delay limit reached (${FUNCTION})"
                return $DRETVAL
                ;;
            $ERR_MAX_TRIES_REACHED)
                log_error "Retry limit reached (max=$MAX_RETRIES)"
                return $DRETVAL
                ;;
            $ERR_CAPTCHA)
                log_error "Error decoding captcha (${FUNCTION})"
                return $DRETVAL
                ;;
            $ERR_SYSTEM)
                log_error "System failure (${FUNCTION})"
                return $DRETVAL
                ;;
            $ERR_BAD_COMMAND_LINE)
                log_error 'Wrong module option, check your command line'
                return $DRETVAL
                ;;
            *)
                log_error "Failed inside ${FUNCTION}() [$DRETVAL]"
                return $ERR_FATAL
                ;;
        esac

        # Sanity check
        if test -z "$FILE_URL"; then
            log_error 'Output URL expected'
            return $ERR_FATAL
        fi

        # Sanity check 2 (no relative url)
        if [[ $FILE_URL = /* ]]; then
            log_error "Output URL is not valid: $FILE_URL"
            return $ERR_FATAL
        fi

        # Sanity check 3
        if [ "$FILE_URL" = "$FILE_NAME" ]; then
            log_error 'Output filename is wrong, check module download function'
            FILE_NAME=""
        fi

        # Sanity check 4
        if [[ $FILE_URL = $(basename_url "$FILE_URL") ]]; then
            log_error "Output URL is not valid: $FILE_URL"
            return $ERR_FATAL
        fi

        if test -z "$FILE_NAME"; then
            if [[ $FILE_URL = */ ]]; then
                log_notice 'Output filename not specified, module download function might be wrong'
                FILE_NAME="dummy-$$"
            else
                FILE_NAME=$(basename_file "${FILE_URL%%\?*}" | tr -d '\r\n' | \
                    html_to_utf8 | uri_decode)
            fi
        fi

        # Sanity check 5
        if [[ $FILE_NAME =~ $'\r' ]]; then
            log_debug 'filename contains \r, remove it'
            FILE_NAME=${FILE_NAME//$'\r'}
        fi

        # On most filesystems, maximum filename length is 255
        # http://en.wikipedia.org/wiki/Comparison_of_file_systems
        if [ "${#FILE_NAME}" -ge 255 ]; then
            FILE_NAME="${FILE_NAME:0:254}"
            log_debug 'filename is too long, truncating it'
        fi

        # Sanity check 6
        if [[ $FILE_NAME =~ / ]]; then
            log_debug 'filename contains slashes, translate to underscore'
            FILE_NAME=${FILE_NAME//\//_}
        fi

        FILE_URL=$(uri_encode <<< "$FILE_URL")

        log_notice "File URL: $FILE_URL"
        log_notice "Filename: $FILE_NAME"

        # Process "final download link" here
        if [ -z "$SKIP_FINAL" ]; then
            local FILENAME_TMP FILENAME_OUT
            local -a CURL_ARGS=()

            # Temporary download filename (with full path)
            if test "$TMP_DIR"; then
                FILENAME_TMP="$TMP_DIR/$FILE_NAME"
            elif test "$OUT_DIR"; then
                FILENAME_TMP="$OUT_DIR/$FILE_NAME"
            else
                FILENAME_TMP=$FILE_NAME
            fi

            # Final filename (with full path)
            if test "$OUT_DIR"; then
                FILENAME_OUT="$OUT_DIR/$FILE_NAME"
            else
                FILENAME_OUT=$FILE_NAME
            fi

            if [ -n "$NOOVERWRITE" -a -f "$FILENAME_OUT" ]; then
                if [ "$FILENAME_OUT" = "$FILENAME_TMP" ]; then
                    FILENAME_OUT=$(create_alt_filename "$FILENAME_OUT")
                    FILENAME_TMP=$FILENAME_OUT
                else
                    FILENAME_OUT=$(create_alt_filename "$FILENAME_OUT")
                fi
                FILE_NAME=$(basename_file "$FILENAME_OUT")
            fi

            if test "$TEMP_RENAME"; then
                FILENAME_TMP="$FILENAME_TMP.part"
            fi

            if [ "$FILENAME_OUT" = "$FILENAME_TMP" ]; then
                if [ -f "$FILENAME_OUT" ]; then
                    # Can we overwrite destination file?
                    if [ ! -w "$FILENAME_OUT" ]; then
                        module_config_resume "$MODULE" && \
                            log_error "error: no write permission, cannot resume final file ($FILENAME_OUT)" || \
                            log_error "error: no write permission, cannot overwrite final file ($FILENAME_OUT)"
                        return $ERR_SYSTEM
                    fi

                    if [ -s "$FILENAME_OUT" ]; then
                        module_config_resume "$MODULE" && \
                            CURL_ARGS=("${CURL_ARGS[@]}" -C -)
                    fi
                fi
            else
                if [ -f "$FILENAME_OUT" ]; then
                    # Can we overwrite destination file?
                    if [ ! -w "$FILENAME_OUT" ]; then
                        log_error "error: no write permission, cannot overwrite final file ($FILENAME_OUT)"
                        return $ERR_SYSTEM
                    fi
                    log_notice "warning: final file will be overwritten ($FILENAME_OUT)"
                fi

                if [ -f "$FILENAME_TMP" ]; then
                    # Can we overwrite temporary file?
                    if [ ! -w "$FILENAME_TMP" ]; then
                        module_config_resume "$MODULE" && \
                            log_error "error: no write permission, cannot resume tmp/part file ($FILENAME_TMP)" || \
                            log_error "error: no write permission, cannot overwrite tmp/part file ($FILENAME_TMP)"
                        return $ERR_SYSTEM
                    fi

                    if [ -s "$FILENAME_TMP" ] ; then
                        module_config_resume "$MODULE" && \
                            CURL_ARGS=("${CURL_ARGS[@]}" -C -)
                    fi
                fi
            fi

            # Reuse previously created temporary file
            :> "$DRESULT"

            # Give extra parameters to curl (custom HTTP headers, ...)
            ANAME=$(module_config_need_extra "$MODULE")
            if test -n "$ANAME"; then
                local -a CURL_EXTRA="$ANAME[@]"
                local OPTION
                for OPTION in "${!CURL_EXTRA}"; do
                    log_debug "adding extra curl options: '$OPTION'"
                    CURL_ARGS+=("$OPTION")
                done
            fi

            if module_config_need_cookie "$MODULE"; then
                if COOKIE_FILE=$(create_tempfile); then
                    echo "$COOKIE_JAR" > "$COOKIE_FILE"
                    CURL_ARGS+=(-b "$COOKIE_FILE")
                fi
            fi

            DRETVAL=0
            curl_with_log "${CURL_ARGS[@]}" -w '%{http_code}' --fail --globoff \
                -o "$FILENAME_TMP" "$FILE_URL" >"$DRESULT" || DRETVAL=$?

            read STATUS < "$DRESULT"
            rm -f "$DRESULT"

            if module_config_need_cookie "$MODULE"; then
                rm -f "$COOKIE_FILE"
            fi

            if [ "$DRETVAL" -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
                # Obtained HTTP return status are 200 and 206
                if module_config_resume "$MODULE"; then
                    log_notice 'Partial content downloaded, recall download function'
                    continue
                fi
                DRETVAL=$ERR_NETWORK

            elif [ "$DRETVAL" -eq $ERR_NETWORK ]; then
                if [[ $STATUS -gt 0 ]]; then
                    log_error "Unexpected HTTP code $STATUS"
                fi
            fi

            if [ "$DRETVAL" -ne 0 ]; then
                return $DRETVAL
            fi

            if [[ "$FILE_URL" = file://* ]]; then
                log_notice "delete temporary file: ${FILE_URL:7}"
                rm -f "${FILE_URL:7}"

            elif [[ $STATUS -eq 416 ]]; then
                # If module can resume transfer, we assume here that this error
                # means that file have already been downloaded earlier.
                # We should do a HTTP HEAD request to check file length but
                # a lot of hosters do not allow it.
                if module_config_resume "$MODULE"; then
                    log_error 'Resume error (bad range), skip download'
                else
                    log_error 'Resume error (bad range), restart download'
                    rm -f "$FILENAME_TMP"
                    continue
                fi
            elif [ "${STATUS:0:2}" != 20 ]; then
                log_error "Unexpected HTTP code $STATUS, module outdated or upstream updated?"
                return $ERR_NETWORK
            fi

            chmod 644 "$FILENAME_TMP" || log_error "chmod failed: $FILENAME_TMP"

            if [ "$FILENAME_TMP" != "$FILENAME_OUT" ]; then
                test "$TEMP_RENAME" || \
                    log_notice "Moving file to output directory: ${OUT_DIR:-.}"
                mv -f "$FILENAME_TMP" "$FILENAME_OUT"
            fi
        fi

        mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" OK "$FILENAME_OUT"

        # Post-processing script
        if [ -n "$POST_COMMAND" ]; then
            COOKIE_FILE=$(create_tempfile) && echo "$COOKIE_JAR" > "$COOKIE_FILE"
            DRETVAL=0
            $(exec "$POST_COMMAND" "$MODULE" "$URL_ENCODED" "$COOKIE_FILE" \
                "$FILE_URL" "$FILE_NAME" >/dev/null) || DRETVAL=$?

            test -f "$COOKIE_FILE" && rm -f "$COOKIE_FILE"

            if [ $DRETVAL -ne 0 ]; then
                log_error "Post-processing script exited with status $DRETVAL, continue anyway"
            fi
        fi

        # Pretty print results
        local -a DATA=("$MODULE" "$FILE_NAME" "$OUT_DIR" "$COOKIE_JAR" \
                    "$URL_ENCODED" "$FILE_URL")
        pretty_print $INDEX DATA[@] "${PRINTF_FORMAT:-%F}"

        return 0
    done

    return $ERR_SYSTEM
}

# Plowdown printf format
# ---
# Interpreted sequences are:
# %c: final cookie filename (with output directory)
# %C: %c or empty string if module does not require it
# %d: download (final) url
# %f: destination (local) filename
# %F: destination (local) filename (with output directory)
# %m: module name
# %u: download (source) url
# and also:
# %n: newline
# %t: tabulation
# %%: raw %
# ---
#
# Check user given format
# $1: format string
pretty_check() {
    # This must be non greedy!
    local S TOKEN
    S=${1//%[cdfmuCFnt%]}
    TOKEN=$(parse_quiet . '\(%.\)' <<< "$S")
    if [ -n "$TOKEN" ]; then
        log_error "Bad format string: unknown sequence << $TOKEN >>"
        return $ERR_BAD_COMMAND_LINE
    fi
}

# $1: unique number
# $2: array[@] (module, dfile, ddir, cdata, dls, dlf)
# $3: format string
# Note: Don't chmod cookie file (keep strict permissions)
pretty_print() {
    local -r N=$(printf %04d $1)
    local -ar A=("${!2}")
    local FMT=$3
    local COOKIE_FILE

    test "${FMT#*%m}" != "$FMT" && FMT=$(replace '%m' "${A[0]}" <<< "$FMT")
    test "${FMT#*%f}" != "$FMT" && FMT=$(replace '%f' "${A[1]}" <<< "$FMT")

    if test "${FMT#*%F}" != "$FMT"; then
        if test "${A[2]}"; then
            FMT=$(replace '%F' "${A[2]}/${A[1]}" <<< "$FMT")
        else
            FMT=$(replace '%F' "${A[1]}" <<< "$FMT")
        fi
    fi

    test "${FMT#*%u}" != "$FMT" && FMT=$(replace '%u' "${A[4]}" <<< "$FMT")
    test "${FMT#*%d}" != "$FMT" && FMT=$(replace '%d' "${A[5]}" <<< "$FMT")

    # Note: Drop "HttpOnly" attribute, as it is not covered in the RFCs
    if test "${FMT#*%c}" != "$FMT"; then
        if test "${A[2]}"; then
            COOKIE_FILE="${A[2]}/plowdown-cookies-$N.txt"
        else
            COOKIE_FILE="plowdown-cookies-$N.txt"
        fi
        sed -e 's/^#HttpOnly_//' <<< "${A[3]}" > "$COOKIE_FILE"
        FMT=$(replace '%c' "${COOKIE_FILE#./}" <<< "$FMT")
    fi
    if test "${FMT#*%C}" != "$FMT"; then
        if module_config_need_cookie "${A[0]}"; then
            if test "${A[2]}"; then
                COOKIE_FILE="${A[2]}/plowdown-cookies-$N.txt"
            else
                COOKIE_FILE="plowdown-cookies-$N.txt"
            fi
            sed -e 's/^#HttpOnly_//' <<< "${A[3]}" > "$COOKIE_FILE"
        else
            COOKIE_FILE=''
        fi
        FMT=$(replace '%C' "$COOKIE_FILE" <<< "$FMT")
    fi

    test "${FMT#*%t}" != "$FMT" && FMT=$(replace '%t' '	' <<< "$FMT")
    test "${FMT#*%%}" != "$FMT" && FMT=$(replace '%%' '%' <<< "$FMT")

    if test "${FMT#*%n}" != "$FMT"; then
        # Don't lose trailing newlines
        FMT=$(replace '%n' $'\n' <<< "$FMT" ; echo -n x)
        echo -n "${FMT%x}"
    else
        echo "$FMT"
    fi
}

#
# Main
#

# Check interpreter
if (( ${BASH_VERSINFO[0]} * 100 + ${BASH_VERSINFO[1]} <= 400 )); then
    echo 'plowdown: Your shell is too old. Bash 4.1+ is required.' >&2
    echo "plowdown: Your version is $BASH_VERSION" >&2
    exit 1
fi

# Get library directory
LIBDIR=$(absolute_path "$0")

set -e # enable exit checking

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'download') || exit
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Process command-line (plowdown early options)
eval "$(process_core_options 'plowdown' "$EARLY_OPTIONS" "$@")" || exit

test "$HELPFULL" && { usage 1; exit 0; }
test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

# Get configuration file options. Command-line is partially parsed.
test -z "$NO_PLOWSHARERC" && \
    process_configfile_options '[Pp]lowdown' "$MAIN_OPTIONS" "$EXT_PLOWSHARERC"

declare -a COMMAND_LINE_MODULE_OPTS COMMAND_LINE_ARGS RETVALS
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}")

# Process command-line (plowdown options).
# Note: Ignore returned UNUSED_ARGS[@], it will be empty.
eval "$(process_core_options 'plowdown' "$MAIN_OPTIONS" "${UNUSED_OPTS[@]}")" || exit

# Verify verbose level
if [ -n "$QUIET" ]; then
    declare -r VERBOSE=0
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

if [ $# -lt 1 ]; then
    log_error 'plowdown: no URL specified!'
    log_error "plowdown: try \`plowdown --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

log_report_info
log_report "plowdown version $VERSION"

if [ -n "$EXT_PLOWSHARERC" ]; then
    if [ -n "$NO_PLOWSHARERC" ]; then
        log_notice 'plowdown: --no-plowsharerc selected and prevails over --plowsharerc'
    else
        log_notice 'plowdown: using alternate configuration file'
    fi
fi

if [ -n "$TEMP_DIR" ]; then
    TMPDIR=${TEMP_DIR%/}
    log_notice "Temporary directory: $TMPDIR"
fi

if [ -n "$OUTPUT_DIR" ]; then
    log_notice "Output directory: ${OUTPUT_DIR%/}"
elif [ ! -w "$PWD" ]; then
    test "$CHECK_LINK" || log_notice 'Warning: Current directory is not writable!'
fi

if [ -n "$GLOBAL_COOKIES" ]; then
    log_notice 'plowdown: using provided cookies file'
fi

if [ -n "$PRINTF_FORMAT" ]; then
    pretty_check "$PRINTF_FORMAT" || exit
fi

# Print chosen options
[ -n "$NOOVERWRITE" ] && log_debug 'plowdown: --no-overwrite selected'

if [ -n "$CAPTCHA_PROGRAM" ]; then
    log_debug 'plowdown: --captchaprogram selected'
fi

if [ -n "$CAPTCHA_METHOD" ]; then
    captcha_method_translate "$CAPTCHA_METHOD" || exit
    log_notice "plowdown: force captcha method ($CAPTCHA_METHOD)"
else
    [ -n "$CAPTCHA_9KWEU" ] && log_debug 'plowdown: --9kweu selected'
    [ -n "$CAPTCHA_ANTIGATE" ] && log_debug 'plowdown: --antigate selected'
    [ -n "$CAPTCHA_BHOOD" ] && log_debug 'plowdown: --captchabhood selected'
    [ -n "$CAPTCHA_DEATHBY" ] && log_debug 'plowdown: --deathbycaptcha selected'
fi

if [ -z "$NO_CURLRC" -a -f "$HOME/.curlrc" ]; then
    log_debug 'using local ~/.curlrc'
fi

MODULE_OPTIONS=$(get_all_modules_options "$MODULES" DOWNLOAD)

# Process command-line (all module options)
eval "$(process_all_modules_options 'plowdown' "$MODULE_OPTIONS" \
    "${UNUSED_OPTS[@]}")" || exit

# Prepend here to keep command-line order
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}" "${COMMAND_LINE_ARGS[@]}")
COMMAND_LINE_MODULE_OPTS=("${UNUSED_OPTS[@]}")

if [ ${#COMMAND_LINE_ARGS[@]} -eq 0 ]; then
    log_error 'plowdown: no URL specified!'
    log_error "plowdown: try \`plowdown --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

# Sanity check
for MOD in $MODULES; do
    if ! declare -f "${MOD}_download" > /dev/null; then
        log_error "plowdown: module \`${MOD}_download' function was not found"
        exit $ERR_BAD_COMMAND_LINE
    fi
done

set_exit_trap

# Save umask
declare -r UMASK=$(umask)
test "$UMASK" && umask 0066

# Remember last host because hosters may require waiting between
# sucessive downloads.
PREVIOUS_HOST=none

# Count downloads (1-based index)
declare -i INDEX=1

for ITEM in "${COMMAND_LINE_ARGS[@]}"; do
    OLD_IFS=$IFS
    IFS=$'\n'
    ELEMENTS=($(process_item "$ITEM"))
    IFS=$OLD_IFS

    TYPE=${ELEMENTS[0]}
    unset ELEMENTS[0]

    for URL in "${ELEMENTS[@]}"; do
        MRETVAL=0
        MODULE=$(get_module "$URL" "$MODULES") || true

        if [ -z "$MODULE" ]; then
            if match_remote_url "$URL"; then
                # Test for simple HTTP 30X redirection
                # (disable User-Agent because some proxy can fake it)
                log_debug 'No module found, try simple redirection'

                URL_ENCODED=$(uri_encode <<< "$URL")
                HEADERS=$(curl --user-agent '' --head "$URL_ENCODED") || true
                URL_TEMP=$(grep_http_header_location_quiet <<< "$HEADERS")

                if [ -n "$URL_TEMP" ]; then
                    MODULE=$(get_module "$URL_TEMP" "$MODULES") || MRETVAL=$?
                    test "$MODULE" && URL="$URL_TEMP"
                elif test "$NO_MODULE_FALLBACK"; then
                    log_notice 'No module found, do a simple HTTP GET as requested'
                    MODULE='module_null'
                else
                    match 'https\?://[[:digit:]]\{1,3\}\.[[:digit:]]\{1,3\}\.[[:digit:]]\{1,3\}\.[[:digit:]]\{1,3\}/' \
                        "$URL" && log_notice "Raw IPv4 address not expected. Provide an URL with a DNS name."
                    test "$HEADERS" && \
                        log_debug "remote server reply: $(echo "$HEADERS" | first_line | tr -d '\r\n')"
                    MRETVAL=$ERR_NOMODULE
                fi
            else
                log_debug "Skip: '$URL' (in $ITEM) doesn't seem to be a link"
                MRETVAL=$ERR_NOMODULE
            fi
        fi

        if [ $MRETVAL -ne 0 ]; then
            match_remote_url "$URL" && \
                log_error "Skip: no module for URL ($(basename_url "$URL")/)"

            # Check if plowlist can handle $URL
            if [ -z "$MODULES_LIST" ]; then
                MODULES_LIST=$(grep_list_modules 'list' 'download') || true
                for MODULE in $MODULES_LIST; do
                    source "$LIBDIR/modules/$MODULE.sh"
                done
            fi
            MODULE=$(get_module "$URL" "$MODULES_LIST") || true
            if [ -n "$MODULE" ]; then
                log_notice "Note: This URL ($MODULE) is supported by plowlist"
            fi

            RETVALS+=($MRETVAL)
            mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" NOMODULE
        elif test "$GET_MODULE"; then
            RETVALS+=(0)
            echo "$MODULE"
        else
            # Get configuration file module options
            test -z "$NO_PLOWSHARERC" && \
                process_configfile_module_options '[Pp]lowdown' "$MODULE" DOWNLOAD "$EXT_PLOWSHARERC"

            eval "$(process_module_options "$MODULE" DOWNLOAD \
                "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

            ${MODULE}_vars_set
            download "$MODULE" "$URL" "$TYPE" "$ITEM" "${OUTPUT_DIR%/}" \
                "$TMPDIR" "${MAXRETRIES:-2}" "$PREVIOUS_HOST" || MRETVAL=$?
            ${MODULE}_vars_unset

            # Link explicitly skipped
            if [ -n "$PRE_COMMAND" -a $MRETVAL -eq $ERR_NOMODULE ]; then
                PREVIOUS_HOST=none
                MRETVAL=0
            else
                PREVIOUS_HOST=$(basename_url "$URL")
            fi

            RETVALS+=($MRETVAL)
            (( ++INDEX ))
        fi
    done
done

# Restore umask
test "$UMASK" && umask $UMASK

if [ ${#RETVALS[@]} -eq 0 ]; then
    exit 0
elif [ ${#RETVALS[@]} -eq 1 ]; then
    exit ${RETVALS[0]}
else
    log_debug "retvals:${RETVALS[@]}"
    # Drop success values
    RETVALS=(${RETVALS[@]/#0*} -$ERR_FATAL_MULTIPLE)

    exit $((ERR_FATAL_MULTIPLE + ${RETVALS[0]}))
fi
