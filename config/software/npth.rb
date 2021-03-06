#
# Copyright:: Copyright (c) 2017 GitLab Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

name 'npth'
default_version '1.5'

license 'LGPL-2.1'
license_file 'COPYING.LIB'

source url: "https://www.gnupg.org/ftp/gcrypt/npth/npth-#{version}.tar.bz2",
       sha256: '294a690c1f537b92ed829d867bee537e46be93fbd60b16c04630fbbfcd9db3c2'

relative_path "npth-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  command './configure ' \
    "--prefix=#{install_dir}/embedded --disable-doc", env: env

  make "-j #{workers}", env: env
  make 'install', env: env
end

project.exclude "embedded/bin/npth-config"
