#!/bin/sh

# This is the custom build script for the viewer
#
# It must be run by the Linden Lab build farm shared buildscript because
# it relies on the environment that sets up, functions it provides, and
# the build result post-processing it does.
#
# The shared buildscript build.sh invokes this because it is named 'build.sh',
# which is the default custom build script name in buildscripts/hg/BuildParams
#
# PLEASE NOTE:
#
# * This script is interpreted on three platforms, including windows and cygwin
#   Cygwin can be tricky....
# * The special style in which python is invoked is intentional to permit
#   use of a native python install on windows - which requires paths in DOS form

check_for()
{
    if [ -e "$2" ]; then found_dict='FOUND'; else found_dict='MISSING'; fi
    echo "$1 ${found_dict} '$2' " 1>&2
}

build_dir_Darwin()
{
  echo build-darwin-i386
}

build_dir_Linux()
{
  echo build-linux-i686
}

build_dir_CYGWIN()
{
  echo build-vc120
}

viewer_channel_suffix()
{
    local package_name="$1"
    local suffix_var="${package_name}_viewer_channel_suffix"
    local suffix=$(eval "echo \$${suffix_var}")
    if [ "$suffix"x = ""x ]
    then
        echo ""
    else
        echo "_$suffix"
    fi
}

installer_Darwin()
{
  local package_name="$1"
  local package_dir="$(build_dir_Darwin ${last_built_variant:-Release})/newview/"
  local pattern=".*$(viewer_channel_suffix ${package_name})_[0-9]+_[0-9]+_[0-9]+_[0-9]+_i386\\.dmg\$"
  # since the additional packages are built after the base package,
  # sorting oldest first ensures that the unqualified package is returned
  # even if someone makes a qualified name that duplicates the last word of the base name
  local package=$(ls -1tr "$package_dir" 2>/dev/null | grep -E "$pattern" | head -n 1)
  test "$package"x != ""x && echo "$package_dir/$package"
}

installer_Linux()
{
  local package_name="$1"
  local package_dir="$(build_dir_Linux ${last_built_variant:-Release})/newview/"
  local pattern=".*$(viewer_channel_suffix ${package_name})_[0-9]+_[0-9]+_[0-9]+_[0-9]+_i686\\.tar\\.bz2\$"
  # since the additional packages are built after the base package,
  # sorting oldest first ensures that the unqualified package is returned
  # even if someone makes a qualified name that duplicates the last word of the base name
  package=$(ls -1tr "$package_dir" 2>/dev/null | grep -E "$pattern" | head -n 1)
  test "$package"x != ""x && echo "$package_dir/$package"
}

installer_CYGWIN()
{
  local package_name="$1"
  local variant=${last_built_variant:-Release}
  local build_dir=$(build_dir_CYGWIN ${variant})
  local package_dir
  if [ "$package_name"x = ""x ]
  then
      package_dir="${build_dir}/newview/${variant}"
  else
      package_dir="${build_dir}/newview/${package_name}/${variant}"
  fi
  if [ -r "${package_dir}/touched.bat" ]
  then
    local package_file=$(sed 's:.*=::' "${package_dir}/touched.bat")
    echo "${package_dir}/${package_file}"
  fi
}

pre_build()
{
  local variant="$1"
  begin_section "Configure $variant"
    [ -n "$master_message_template_checkout" ] \
    && [ -r "$master_message_template_checkout/message_template.msg" ] \
    && template_verifier_master_url="-DTEMPLATE_VERIFIER_MASTER_URL=file://$master_message_template_checkout/message_template.msg"

    "$autobuild" configure --quiet -c $variant -- \
     -DPACKAGE:BOOL=ON \
     -DRELEASE_CRASH_REPORTING:BOOL=ON \
     -DVIEWER_CHANNEL:STRING="\"$viewer_channel\"" \
     -DGRID:STRING="\"$viewer_grid\"" \
     -DLL_TESTS:BOOL="$run_tests" \
     -DTEMPLATE_VERIFIER_OPTIONS:STRING="$template_verifier_options" $template_verifier_master_url

  end_section "Configure $variant"
}

package_llphysicsextensions_tpv()
{
  begin_section "PhysicsExtensions_TPV"
  tpv_status=0
  if [ "$variant" = "Release" ]
  then 
      llpetpvcfg=$build_dir/packages/llphysicsextensions/autobuild-tpv.xml
      "$autobuild" build --quiet --config-file $llpetpvcfg -c Tpv
      
      # capture the package file name for use in upload later...
      PKGTMP=`mktemp -t pgktpv.XXXXXX`
      trap "rm $PKGTMP* 2>/dev/null" 0
      "$autobuild" package --quiet --config-file $llpetpvcfg --results-file "$(native_path $PKGTMP)"
      tpv_status=$?
      if [ -r "${PKGTMP}" ]
      then
          cat "${PKGTMP}" >> "$build_log"
          eval $(cat "${PKGTMP}") # sets autobuild_package_{name,filename,md5}
          autobuild_package_filename="$(shell_path "${autobuild_package_filename}")"
          echo "${autobuild_package_filename}" > $build_dir/llphysicsextensions_package
      fi
  else
      record_event "Do not provide llphysicsextensions_tpv for $variant"
      llphysicsextensions_package=""
  fi
  end_section "PhysicsExtensions_TPV"
  return $tpv_status
}

build()
{
  local variant="$1"
  if $build_viewer
  then
    "$autobuild" build --quiet --no-configure -c $variant
    build_ok=$?

    # Run build extensions
    if [ $build_ok -eq 0 -a -d ${build_dir}/packages/build-extensions ]; then
        for extension in ${build_dir}/packages/build-extensions/*.sh; do
            begin_section "Extension $extension"
            . $extension
            end_section "Extension $extension"
            if [ $build_ok -ne 0 ]; then
                break
            fi
        done
    fi

    # *TODO: Make this a build extension.
    package_llphysicsextensions_tpv
    tpvlib_build_ok=$?
    if [ $build_ok -eq 0 -a $tpvlib_build_ok -eq 0 ]
    then
      echo true >"$build_dir"/build_ok
    else
      echo false >"$build_dir"/build_ok
    fi
  fi
}

# Check to see if we were invoked from the wrapper, if not, re-exec ourselves from there
if [ "x$arch" = x ]
then
  top=`hg root`
  if [ -x "$top/../buildscripts/hg/bin/build.sh" ]
  then
    exec "$top/../buildscripts/hg/bin/build.sh" "$top"
  else
    cat <<EOF
This script, if called in a development environment, requires that the branch
independent build script repository be checked out next to this repository.
This repository is located at http://bitbucket.org/lindenlabinternal/sl-buildscripts
EOF
    exit 1
  fi
fi

# Check to see if we're skipping the platform
eval '$build_'"$arch" || pass

# ensure AUTOBUILD is in native path form for child processes
AUTOBUILD="$(native_path "$AUTOBUILD")"
# set "$autobuild" to cygwin path form for use locally in this script
autobuild="$(shell_path "$AUTOBUILD")"
if [ ! -x "$autobuild" ]
then
  record_failure "AUTOBUILD not executable: '$autobuild'"
  exit 1
fi

# load autobuild provided shell functions and variables
eval "$("$autobuild" source_environment)"

# dump environment variables for debugging
begin_section "Environment"
env|sort
end_section "Environment"

# Now run the build
succeeded=true
build_processes=
last_built_variant=
for variant in $variants
do
  eval '$build_'"$variant" || continue
  eval '$build_'"$arch"_"$variant" || continue

  # Only the last built arch is available for upload
  last_built_variant="$variant"

  build_dir=`build_dir_$arch $variant`
  build_dir_stubs="$build_dir/win_setup/$variant"

  begin_section "Initialize $variant Build Directory"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  mkdir -p "$build_dir/tmp"
  end_section "Initialize $variant Build Directory"

  if pre_build "$variant" "$build_dir"
  then
      begin_section "Build $variant"
      build "$variant" "$build_dir" 2>&1 | tee -a "$build_log" | sed -n 's/^ *\(##teamcity.*\)/\1/p'
      if `cat "$build_dir/build_ok"`
      then
          case "$variant" in
            Release)
              if [ -r "$build_dir/autobuild-package.xml" ]
              then
                  begin_section "Autobuild metadata"
                  upload_item docs "$build_dir/autobuild-package.xml" text/xml
                  if [ "$arch" != "Linux" ]
                  then
                      record_dependencies_graph # defined in buildscripts/hg/bin/build.sh
                  else
                      record_event "TBD - no dependency graph for linux (probable python version dependency)" 1>&2
                  fi
                  end_section "Autobuild metadata"
              else
                  record_event "no autobuild metadata at '$build_dir/autobuild-package.xml'"
              fi
              ;;
            Doxygen)
              if [ -r "$build_dir/doxygen_warnings.log" ]
              then
                  record_event "Doxygen warnings generated; see doxygen_warnings.log"
                  upload_item log "$build_dir/doxygen_warnings.log" text/plain
              fi
              if [ -d "$build_dir/doxygen/html" ]
              then
                  tar -c -f "$build_dir/viewer-doxygen.tar.bz2" --strip-components 3  "$build_dir/doxygen/html"
                  upload_item docs "$build_dir/viewer-doxygen.tar.bz2" binary/octet-stream
              fi
              ;;
            *)
              ;;
          esac

      else
          record_failure "Build of \"$variant\" failed."
      fi
      end_section "Build $variant"
  else
      record_event "configure for $variant failed: build skipped"
  fi

  if ! $succeeded 
  then
      record_event "remaining variants skipped due to $variant failure"
      break
  fi
done

# build debian package
if [ "$arch" == "Linux" ]
then
  if $succeeded
  then
    if $build_viewer_deb && [ "$last_built_variant" == "Release" ]
    then
      begin_section "Build Viewer Debian Package"
      # have_private_repo=false - <FS:TM> FS doesnt use this
      # mangle the changelog
      dch --force-bad-version \
          --distribution unstable \
          --newversion "${VIEWER_VERSION}" \
          "Automated build #$build_id, repository $branch revision $revision." \
          >> "$build_log" 2>&1

      # build the debian package
      $pkg_default_debuild_command  >>"$build_log" 2>&1 || record_failure "\"$pkg_default_debuild_command\" failed."

      # Unmangle the changelog file
      hg revert debian/changelog

      end_section "Build Viewer Debian Package"

      # Run debian extensions
      if [ -d ${build_dir}/packages/debian-extensions ]; then
          for extension in ${build_dir}/packages/debian-extensions/*.sh; do
              . $extension
          done
      fi
      # Move any .deb results.
      mv ${build_dir}/packages/*.deb ../ 2>/dev/null || true

      # upload debian package and create repository
      begin_section "Upload Debian Repository"
      for deb_file in ../*.deb; do
        upload_item debian $deb_file binary/octet-stream
      done
      if [ -d "$build_log_dir/debian_repo" ]
      then
        pushd "$build_log_dir/debian_repo"
        cat > Release <<EOF
Archive: stable
Component: main
Origin: Teamcity
Label: Teamcity built .debs
Architecture: i386 amd64 any
EOF
        if dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz \
        && dpkg-scansources . /dev/null | gzip -9c > Sources.gz
        then
          begin_section Packages.gz
          gunzip --stdout Packages.gz
          for file in *.deb
          do  
            stat "$file" | sed 2q
            md5sum "$file"
          done
          end_section Packages.gz

          for file in *
          do
            upload_item debian_repo "$file" binary/octet-stream
          done
        else
          record_failure 'Unable to generate Packages.gz or Sources.gz'
        fi
        popd

        process_pending_uploads

        # Rename the local debian_repo directory so that the master buildscript
        # doesn't make a remote repo again.

        mv $build_log_dir/debian_repo $build_log_dir/debian_repo_pushed
      fi
      end_section "Upload Debian Repository"
      
    else
      echo debian build not enabled
    fi
  else
    echo skipping debian build due to failed build.
  fi
fi

# check status and upload results to S3
if $succeeded
then
  if $build_viewer
  then
    begin_section Upload Installer
    # Upload installer
    package=$(installer_$arch)
    if [ x"$package" = x ] || test -d "$package"
    then
      # Coverity doesn't package, so it's ok, anything else is fail
      succeeded=$build_coverity
    else
      # Upload base package.
      upload_item installer "$package" binary/octet-stream
      upload_item quicklink "$package" binary/octet-stream
      [ -f $build_dir/summary.json ] && upload_item installer $build_dir/summary.json text/plain

      # Upload additional packages.
      for package_id in $additional_packages
      do
        package=$(installer_$arch "$package_id")
        if [ x"$package" != x ]
        then
          upload_item installer "$package" binary/octet-stream
          upload_item quicklink "$package" binary/octet-stream
        else
          record_failure "Failed to find additional package for '$package_id'."
        fi
      done

      case "$last_built_variant" in
      Release)
        # Upload crash reporter files
        for symbolfile in $symbolfiles
        do
          upload_item symbolfile "$build_dir/$symbolfile" binary/octet-stream
        done

        # Upload the actual dependencies used
        if [ -r "$build_dir/packages/installed-packages.xml" ]
        then
            upload_item installer "$build_dir/packages/installed-packages.xml" text/xml
        fi

        # Upload the llphysicsextensions_tpv package, if one was produced
        # *TODO: Make this an upload-extension
        if [ -r "$build_dir/llphysicsextensions_package" ]
        then
            llphysicsextensions_package=$(cat $build_dir/llphysicsextensions_package)
            upload_item private_artifact "$llphysicsextensions_package" binary/octet-stream
        fi
        ;;
      *)
        ;;
      esac

      # Run upload extensions
      if [ -d ${build_dir}/packages/upload-extensions ]; then
          for extension in ${build_dir}/packages/upload-extensions/*.sh; do
              begin_section "Upload Extension $extension"
              . $extension
              end_section "Upload Extension $extension"
          done
      fi
    fi
    end_section Upload Installer
  else
    echo skipping upload of installer
  fi

  
else
  echo skipping upload of installer due to failed build.
fi

# The branch independent build.sh script invoking this script will finish processing
$succeeded || exit 1
