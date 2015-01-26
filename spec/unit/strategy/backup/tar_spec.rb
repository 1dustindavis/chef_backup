require 'spec_helper'
require 'chef/mixin/deep_merge'

describe ChefBackup::Strategy::TarBackup do
  set_common_variables

  subject { described_class.new }

  before do
    allow(subject).to receive(:tmp_dir).and_return(tmp_dir)
    allow(subject).to receive(:backup_time).and_return(backup_time)
  end

  describe '.backup' do
    before do
      noop_external_methods_except(:backup)
      allow(subject).to receive(:enabled_services).and_return(enabled_services)
      allow(subject).to receive(:all_services).and_return(all_services)
      allow(subject).to receive(:dump_db).and_return(true)
    end

    context 'on a frontend' do
      before { private_chef('role' => 'frontend') }

      it 'doesnt stop any services' do
        expect(subject).to_not receive(:stop_service)
        subject.backup
      end

      it 'doesnt dump the db' do
        expect(subject).to_not receive(:dump_db)
        subject.backup
      end
    end

    %w(backend standalone).each do |role|
      context "on a #{role}" do
        context 'during an online backup' do
          before do
            private_chef('role' => role, 'backup' => { 'mode' => 'online' })
          end

          it "doesn't start any services" do
            expect(subject).to_not receive(:start_service)
            subject.backup
          end

          it "doesn't stop any services" do
            expect(subject).to_not receive(:stop_service)
            subject.backup
          end

          it 'dumps the db' do
            expect(subject).to receive(:dump_db).once
            subject.backup
          end
        end

        [
          {
            context: 'when no mode is configured',
            config: { 'role' => role }
          },
          { context: 'during an offline backup',
            config: { 'role' => role, 'backup' => { 'mode' => 'offline' } }
          }
        ].each do |mode|
          context mode[:context] do
            before { private_chef(mode[:config]) }

            it 'stops all services besides keepalived and postgres' do
              expect(subject).to receive(:stop_chef_server).once

              %w(postgresql keepalived).each do |service|
                expect(subject).to_not receive(:stop_service).with(service)
              end

              subject.backup
            end

            it 'starts all the services again' do
              expect(subject).to receive(:start_chef_server).at_least(:once)
              subject.backup
            end

            it 'dumps the db' do
              expect(subject).to receive(:dump_db).once
              subject.backup
            end
          end
        end
      end
    end

    %w(frontend backend standalone).each do |node|
      context "on a #{node}" do
        before { private_chef('role' => node) }

        it 'populates the data map with services and configs' do
          expect(subject).to receive(:populate_data_map).once
          subject.backup
        end

        it 'creates a backup manifest' do
          expect(subject).to receive(:write_manifest).once
          subject.backup
        end

        it 'creates a tarball of the backup' do
          expect(subject).to receive(:create_tarball).once
          subject.backup
        end

        it 'cleans up the temp directory' do
          expect(subject).to receive(:cleanup).at_least(:once)
          subject.backup
        end
      end
    end
  end

  describe '.dump_db' do
    let(:dump_cmd) do
      ['/opt/opscode/embedded/bin/chpst',
       '-u opscode-pgsql',
       '/opt/opscode/embedded/bin/pg_dumpall',
       "> #{tmp_dir}/chef_backup-#{backup_time}.sql"
      ].join(' ')
    end

    let(:tmp_dir) { '/tmp/fuckingshit' }
    let(:backup_time) { Time.now }

    before do
      allow(subject).to receive(:tmp_dir).and_return(tmp_dir)
      allow(subject).to receive(:backup_time).and_return(backup_time)
      allow(subject).to receive(:shell_out!).with(dump_cmd).and_return(true)
      private_chef('postgresql' => { 'username' => 'opscode-pgsql' })
      subject.data_map.add_service('postgresql', '/data/dir')
    end

    %w(backend standalone).each do |role|
      context "on a #{role}" do
        before do
          private_chef('role' => role)
        end

        it 'dumps the db' do
          expect(subject).to receive(:shell_out!).with(dump_cmd)
          subject.dump_db
        end

        it 'updates the data map' do
          subject.dump_db
          expect(subject.data_map.services['postgresql'])
            .to include('pg_dump_success' => true)
        end
      end
    end

    context 'on a frontend' do
      before { private_chef('role' => 'frontend') }

      it "doesn't dump the db" do
        expect(subject).to_not receive(:shell_out).with(/pg_dumpall/)
        subject.dump_db
      end
    end
  end

  describe '.create_tarball' do
    before do
      noop_external_methods_except(:create_tarball)
      allow(subject).to receive(:data_map).and_return(data_map)
      allow(Dir).to receive(:[]).and_return(%w(sql.sql manifest.json))
    end

    it 'creates a tarball with all items in the temp directory' do
      cmd = [
        "tar -czf #{tmp_dir}/chef-backup-#{backup_time}.tgz",
        data_map.services.map { |_, v| v['data_dir'] }.compact.join(' '),
        data_map.configs.map { |_, v| v['data_dir'] }.compact.join(' '),
        Dir["#{tmp_dir}/*"].map { |f| File.basename(f) }.join(' ')
      ].join(' ').strip

      expect(subject).to receive(:shell_out).with(cmd, cwd: tmp_dir)
      subject.create_tarball
    end
  end

  describe '.export_tarball' do
    before do
      noop_external_methods_except(:export_tarball)
      allow(subject).to receive(:export_dir).and_return('/mnt/chef-backups')
    end

    it 'moves the tarball to the archive location' do
      cmd = "rsync -chaz #{tmp_dir}/chef-backup-#{backup_time}.tgz"
      cmd << " #{export_dir}/"

      expect(subject).to receive(:shell_out).with(cmd)
      subject.export_tarball
    end
  end

  describe '.write_manifest' do
    let(:manifest) do
      { 'some' => {
        'nested' => {
          'hash' => true
        },
        'another' => true
      }
      }
    end

    let(:file) { double('file', write: true) }

    before do
      allow(subject).to receive(:manifest).and_return(manifest)
      allow(subject).to receive(:tmp_dir).and_return(tmp_dir)
      allow(File).to receive(:open).and_yield(file)
    end

    it 'converts the manifest to json' do
      json_manifest = JSON.pretty_generate(subject.manifest)
      expect(file).to receive(:write).with(json_manifest)
      subject.write_manifest
    end

    it 'writes a json file to the tmp_dir' do
      expect(File).to receive(:open).with("#{tmp_dir}/manifest.json", 'w')
      subject.write_manifest
    end
  end

  describe '.populate_data_map' do
    let(:services) { %w(opscode-solr4 bookshelf rabbitmq) }
    let(:configs) { %w(opscode opscode-manage opscode-analytics) }
    let(:config) do
      { 'bookshelf' => { 'data_dir' => '/bookshelf/data' },
        'opscode-solr4' => { 'data_dir' => '/solr4/data' },
        'rabbitmq' => { 'data_dir' => '/rabbitmq/data' }
      }
    end

    before do
      allow(subject).to receive(:data_map).and_return(data_map)
      allow(subject).to receive(:stateful_services).and_return(services)
      allow(subject).to receive(:config_directories).and_return(configs)
      %w(add_service add_config).each do |method|
        allow(data_map).to receive(method.to_sym).and_return(true)
      end
    end

    %w(frontend backend standalone).each do |role|
      context "on a #{role}" do
        before { private_chef(config.merge('role' => role)) }

        it 'populates the data map with config directories' do
          configs.each do |config|
            expect(subject.data_map)
              .to receive(:add_config)
              .with(config, "/etc/#{config}")
          end

          subject.populate_data_map
        end
      end
    end

    %w(backend standalone).each do |role|
      context "on a #{role}" do
        before { private_chef(config.merge('role' => role)) }

        it 'populates the data map with service directories' do
          services.each do |service|
            expect(subject.data_map)
              .to receive(:add_service)
              .with(service, config[service]['data_dir'])
          end

          subject.populate_data_map
        end
      end
    end

    context 'on a frontend' do
      before { private_chef(config.merge('role' => 'frontend')) }

      it "doesn't populate the data map with the services" do
        expect(subject.data_map).to_not receive(:add_service)
      end
    end
  end

  describe '.cleanup' do
    before do
      noop_external_methods_except(:cleanup)
      allow(subject).to receive(:tmp_dir).and_return(tmp_dir)
    end

    it 'cleans up all items in the temp directory' do
      expect(FileUtils).to receive(:rm_r).with(tmp_dir)
      subject.cleanup
    end
  end
end
