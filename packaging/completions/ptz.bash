_ptz_complete() {
    local path filesystem_path
    COMPREPLY=()
    while IFS= read -r path; do
        COMPREPLY+=("$path")
    done < <(
        shopt -s nocasematch
        while IFS= read -r path; do
            filesystem_path=$path
            if [[ "$path" == '~/'* ]]; then
                filesystem_path=$HOME/${path:2}
            fi
            if [[ -d "$filesystem_path" || ( -f "$filesystem_path" && "$path" =~ \.(pdf|epub|xps|oxps|cbz|cbt|fb2|mobi|prc|pdb|svg|png|jpg|jpeg|jpe|jfif|jfif-tbnl|tif|tiff|jp2|j2k|jpx|bmp|psd|gif|pnm|pbm|pgm|ppm|pam|pfm)$ ) ]]; then
                printf '%s\n' "$path"
            fi
        done < <(compgen -f -- "$2")
    )
}
complete -o filenames -F _ptz_complete ptz
