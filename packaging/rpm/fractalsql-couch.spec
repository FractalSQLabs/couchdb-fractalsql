# fractalsql-couch.spec
#
# The binary is pre-built by ../build.sh (docker buildx) as a static,
# glibc-only executable. This spec just stages it into an RPM.
#
# Caller passes --define "rpm_arch amd64|arm64" so the spec picks the
# matching dist/${rpm_arch}/fractalsql-couch.

%global rpm_arch %{?rpm_arch}%{!?rpm_arch:amd64}

Name:           fractalsql-couch
Version:        1.0.0
Release:        1%{?dist}
Summary:        FractalSQL external query server for Apache CouchDB

License:        MIT
URL:            https://github.com/FractalSQLabs/couchdb-fractalsql
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  /usr/bin/test
# No explicit glibc Requires. rpmbuild auto-generates per-symbol
# library dependencies by scanning the binary's ELF imports, yielding
# entries like `libc.so.6(GLIBC_2.31)(64bit)` that reflect what the
# binary actually needs. Declaring a blanket `glibc >= X.Y` on top of
# that adds nothing and, if it overshoots what the binary requires,
# refuses installs on targets that the binary could in fact run on
# (e.g. Rocky 9 ships glibc 2.34).
Recommends:     couchdb

# The binary ships already stripped (-Wl,--strip-all); rpmbuild's
# debuginfo machinery has nothing useful to extract.
%global debug_package %{nil}

%description
fractalsql-couch is a CouchDB External Query Server that speaks the
JSON-over-stdio protocol and embeds the FractalSQL Stochastic Fractal
Search engine via LuaJIT. It registers as a query_server language
("fractalsql") so design documents can declare map functions in Lua
with access to the FractalSQL SFS/dFDB optimizer.

LuaJIT and cJSON are statically linked into the binary; no external
LuaJIT runtime is required at deployment time. See
%{_docdir}/%{name}/README_COUCH.txt for the local.ini snippet needed
to register the query server with CouchDB.

%prep
%setup -q

%build
test -f dist/%{rpm_arch}/fractalsql-couch

%install
install -Dm0755 dist/%{rpm_arch}/fractalsql-couch \
    %{buildroot}%{_bindir}/fractalsql-couch
install -Dm0644 packaging/README_COUCH.txt \
    %{buildroot}%{_docdir}/%{name}/README_COUCH.txt
# LICENSE and THIRD-PARTY-NOTICES.md are not copied here: the %license
# directive in %files lifts them directly out of the source tree into
# /usr/share/licenses/%{name}/, which is the RPM-native location.
# Copying them into /usr/share/doc/%{name}/ as well would produce a
# second, unpackaged pair of files and fail check-files.

%post
cat <<'EOF'

fractalsql-couch installed at %{_bindir}/fractalsql-couch.

To register it with CouchDB, add the following to your local.ini
(typically /opt/couchdb/etc/local.ini or /etc/couchdb/local.ini)
under the [query_servers] section, then restart CouchDB:

    [query_servers]
    fractalsql = %{_bindir}/fractalsql-couch

See %{_docdir}/%{name}/README_COUCH.txt for details.

EOF

%files
%license LICENSE
%license THIRD-PARTY-NOTICES.md
%doc %{_docdir}/%{name}/README_COUCH.txt
%{_bindir}/fractalsql-couch

%changelog
* Tue Apr 21 2026 FractalSQLabs <ops@fractalsqlabs.io> - 1.0.0-1
- Initial release: FractalSQL external query server for Apache CouchDB.
- Static LuaJIT + cJSON (glibc-only runtime dependency).
