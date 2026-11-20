function __ptz_complete_paths
    set -l token (commandline -ct)
    complete -C "__ptz_file_candidates $token" |
        string match -ir '^.*(?:/|\.(?:pdf|epub|xps|oxps|cbz|cbt|fb2|mobi|prc|pdb|svg|png|jpg|jpeg|jpe|jfif|jfif-tbnl|tif|tiff|jp2|j2k|jpx|bmp|psd|gif|pnm|pbm|pgm|ppm|pam|pfm))(?:\t.*)?$'
end

complete -c ptz -f -a '(__ptz_complete_paths)'
