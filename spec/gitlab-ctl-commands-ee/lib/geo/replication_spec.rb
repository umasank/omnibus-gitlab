require 'spec_helper'

$LOAD_PATH << './files/gitlab-ctl-commands-ee/lib'
$LOAD_PATH << './files/gitlab-ctl-commands/lib'

require 'geo/replication'
require 'gitlab_ctl/util'

describe Geo::Replication, '#execute' do
  let(:command) { spy('command spy', error?: false) }
  let(:instance) { double(base_path: '/opt/gitlab/embedded', data_path: '/var/opt/gitlab/postgresql/data') }
  let(:file) { spy('file spy') }
  let(:options) { { now: true, host: 'localhost', port: 9999, user: 'my-user', sslmode: 'disable', sslcompression: 1 } }

  subject { described_class.new(instance, options) }

  before do
    allow(instance).to receive(:service_enabled?).and_return(true)
    allow(STDOUT).to receive(:puts)
    allow(subject).to receive(:print)
    allow(File).to receive(:open).and_yield(file)

    allow(GitlabCtl::Util).to receive(:run_command).and_return(command)
  end

  it 'replicates geo database' do
    expect(subject).to receive(:ask_pass).and_return('password')
    expect(GitlabCtl::Util).to receive(:run_command)
      .with(%r{/embedded/bin/pg_basebackup}, anything)

    subject.execute
  end

  context 'when there is TTY available' do
    before do
      allow(STDIN).to receive(:tty?).and_return(true)
    end

    it 'asks for database password in an interactive mode' do
      expect(STDIN).to receive(:getpass).and_return('password')

      subject.execute
    end
  end

  context 'when there is no TTY available' do
    before do
      allow(STDIN).to receive(:tty?).and_return(false)
    end

    it 'asks for a database password in a non-interactive mode' do
      expect(STDIN).to receive(:gets).and_return('pass')

      subject.execute
    end

    it 'strips the password' do
      allow(STDIN).to receive(:gets).and_return("pass\n")

      subject.execute

      expect(file).to have_received(:write).with("localhost:9999:*:my-user:pass\n")
      expect(file).to have_received(:write).with(/password=pass sslmode=disable sslcompression=1'\n/)
    end
  end

  context 'when user has to provide a confirmation text' do
    let(:options) { { now: false, host: 'localhost', port: 9999, user: 'my-user', slot_name: 'foo' } }

    it 'asks for confirmation string' do
      allow(subject).to receive(:ask_pass).and_return('mypass')
      expect(STDIN).to receive(:gets).and_return('replicate')
      expect(GitlabCtl::Util).to receive(:run_command)
        .with("PGPASSFILE=/var/opt/gitlab/postgresql/data/postgresql/.pgpass /opt/gitlab/embedded/embedded/bin/pg_basebackup -h localhost -p 9999 -D /var/opt/gitlab/postgresql/data/postgresql/data -U my-user -v -P -X stream -S foo",
              anything)

      subject.execute
    end
  end
end
