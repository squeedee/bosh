require 'spec_helper'

module Bosh::Director::DeploymentPlan
  describe DatabaseIpProvider do
    subject(:ip_provider) do
      DatabaseIpProvider.new(
        range,
        'fake-network',
        restricted_ips,
        static_ips,
        logger
      )
    end
    let(:deployment_model) { Bosh::Director::Models::Deployment.make }
    let(:restricted_ips) { Set.new }
    let(:static_ips) { Set.new }
    let(:range) { NetAddr::CIDR.create('192.168.0.1/24') }
    let(:instance) do
      instance_double(Instance, model: Bosh::Director::Models::Instance.make, to_s: 'fake-job/0')
    end
    let(:network) { instance_double(ManualNetwork, name: 'fake-network') }

    before do
      Bosh::Director::Config.current_job = Bosh::Director::Jobs::BaseJob.new
      Bosh::Director::Config.current_job.task_id = 'fake-task-id'
    end

    def cidr_ip(ip)
      NetAddr::CIDR.create(ip).to_i
    end

    def create_reservation(ip)
      BD::StaticNetworkReservation.new(instance, network, cidr_ip(ip))
    end

    describe 'allocate_dynamic_ip' do
      context 'when there are no IPs reserved for that network' do
        it 'returns the first in the range' do
          ip_address = ip_provider.allocate_dynamic_ip(instance)

          expected_ip_address = cidr_ip('192.168.0.0')
          expect(ip_address).to eq(expected_ip_address)
        end
      end

      it 'reserves IP as dynamic' do
        ip_provider.allocate_dynamic_ip(instance)
        saved_address = Bosh::Director::Models::IpAddress.first
        expect(saved_address.static).to eq(false)
      end

      context 'when reserving more than one ip' do
        it 'should the next available address' do
          first = ip_provider.allocate_dynamic_ip(instance)
          second = ip_provider.allocate_dynamic_ip(instance)
          expect(first).to eq(cidr_ip('192.168.0.0'))
          expect(second).to eq(cidr_ip('192.168.0.1'))
        end
      end

      context 'when there are restricted ips' do
        let(:restricted_ips) do
          Set.new [
              cidr_ip('192.168.0.0'),
              cidr_ip('192.168.0.1'),
              cidr_ip('192.168.0.3')
            ]
        end

        it 'does not reserve them' do
          expect(ip_provider.allocate_dynamic_ip(instance)).to eq(cidr_ip('192.168.0.2'))
          expect(ip_provider.allocate_dynamic_ip(instance)).to eq(cidr_ip('192.168.0.4'))
        end
      end

      context 'when there are static and restricted ips' do
        let(:restricted_ips) do
          Set.new [
              cidr_ip('192.168.0.0'),
              cidr_ip('192.168.0.3')
            ]
        end

        let(:static_ips) do
          Set.new [
              cidr_ip('192.168.0.1'),
            ]
        end

        it 'does not reserve them' do
          expect(ip_provider.allocate_dynamic_ip(instance)).to eq(cidr_ip('192.168.0.2'))
          expect(ip_provider.allocate_dynamic_ip(instance)).to eq(cidr_ip('192.168.0.4'))
        end
      end

      context 'when there are available IPs between reserved IPs' do
        let(:static_ips) do
          Set.new [
              cidr_ip('192.168.0.0'),
              cidr_ip('192.168.0.1'),
              cidr_ip('192.168.0.3'),
            ]
        end

        before do
          ip_provider.reserve_ip(create_reservation('192.168.0.0'))
          ip_provider.reserve_ip(create_reservation('192.168.0.1'))
          ip_provider.reserve_ip(create_reservation('192.168.0.3'))
        end

        it 'returns first non-reserved IP' do
          ip_address = ip_provider.allocate_dynamic_ip(instance)

          expected_ip_address = cidr_ip('192.168.0.2')
          expect(ip_address).to eq(expected_ip_address)
        end
      end

      context 'when range is greater than max reserved IP' do
        let(:range) { NetAddr::CIDR.create('192.168.2.0/24') }

        let(:static_ips) do
          Set.new [
            cidr_ip('192.168.1.1'),
          ]
        end

        before do
          ip_provider.reserve_ip(create_reservation('192.168.1.1'))
        end

        it 'uses first IP from range' do
          ip_address = ip_provider.allocate_dynamic_ip(instance)

          expected_ip_address = cidr_ip('192.168.2.0')
          expect(ip_address).to eq(expected_ip_address)
        end
      end

      context 'when all IPs are reserved without holes' do
        let(:static_ips) do
          Set.new [
              cidr_ip('192.168.0.0'),
              cidr_ip('192.168.0.1'),
              cidr_ip('192.168.0.2'),
            ]
        end

        before do
          ip_provider.reserve_ip(create_reservation('192.168.0.0'))
          ip_provider.reserve_ip(create_reservation('192.168.0.1'))
          ip_provider.reserve_ip(create_reservation('192.168.0.2'))
        end

        it 'returns IP next after reserved' do
          ip_address = ip_provider.allocate_dynamic_ip(instance)

          expected_ip_address = cidr_ip('192.168.0.3')
          expect(ip_address).to eq(expected_ip_address)
        end
      end

      context 'when all IPs in the range are taken' do
        let(:range) { NetAddr::CIDR.create('192.168.0.0/32') }

        it 'returns nil' do
          expect(ip_provider.allocate_dynamic_ip(instance)).to_not be_nil
          expect(ip_provider.allocate_dynamic_ip(instance)).to be_nil
        end
      end

      context 'when reserving IP fails' do
        let(:range) { NetAddr::CIDR.create('192.168.0.0/30') }

        def fail_saving_ips(ips, fail_error)
          original_saves = {}
          ips.each do |ip|
            ip_address = Bosh::Director::Models::IpAddress.new(
              address: ip,
              network_name: 'fake-network',
              instance: instance.model,
              task_id: Bosh::Director::Config.current_job.task_id
            )
            original_save = ip_address.method(:save)
            original_saves[ip] = original_save
          end

          allow_any_instance_of(Bosh::Director::Models::IpAddress).to receive(:save) do |model|
            if ips.include?(model.address)
              original_save = original_saves[model.address]
              original_save.call
              raise fail_error
            end
            model
          end
        end

        shared_examples :retries_on_race_condition do
          context 'when allocating some IPs fails' do
            before do
              fail_saving_ips([
                  cidr_ip('192.168.0.0'),
                  cidr_ip('192.168.0.1'),
                  cidr_ip('192.168.0.2'),
                ],
                fail_error
              )
            end

            it 'retries until it succeeds' do
              expect(ip_provider.allocate_dynamic_ip(instance)).to eq(cidr_ip('192.168.0.3'))
            end
          end

          context 'when allocating any IP fails' do
            before do
              fail_saving_ips([
                  cidr_ip('192.168.0.0'),
                  cidr_ip('192.168.0.1'),
                  cidr_ip('192.168.0.2'),
                  cidr_ip('192.168.0.3'),
                ],
                fail_error
              )
            end

            it 'retries until there are no more IPs available' do
              expect(ip_provider.allocate_dynamic_ip(instance)).to be_nil
            end
          end
        end

        context 'when sequel validation errors' do
          let(:fail_error) { Sequel::ValidationFailed.new('address and network are not unique') }

          it_behaves_like :retries_on_race_condition
        end

        context 'when postgres unique errors' do
          let(:fail_error) { Sequel::DatabaseError.new('duplicate key value violates unique constraint') }

          it_behaves_like :retries_on_race_condition
        end

        context 'when mysql unique errors' do
          let(:fail_error) { Sequel::DatabaseError.new('Duplicate entry') }

          it_behaves_like :retries_on_race_condition
        end
      end
    end

    describe 'reserve_ip' do
      let(:static_ips) do
        Set.new [
            cidr_ip('192.168.0.2'),
          ]
      end

      let(:reservation) { create_reservation('192.168.0.2') }
      it 'creates IP in database' do
        ip_provider
        expect {
          ip_provider.reserve_ip(reservation)
        }.to change(Bosh::Director::Models::IpAddress, :count).by(1)
        saved_address = Bosh::Director::Models::IpAddress.order(:address).last
        expect(saved_address.address).to eq(cidr_ip('192.168.0.2'))
        expect(saved_address.network_name).to eq('fake-network')
        expect(saved_address.task_id).to eq('fake-task-id')
        expect(saved_address.created_at).to_not be_nil
      end

      context 'when reserving dynamic IP' do
        let(:reservation) { BD::DynamicNetworkReservation.new(instance, network) }

        context 'when IP belongs to dynamic pool' do
          before { reservation.resolve_ip('192.168.0.5') }

          it 'saves IP as dynamic' do
            ip_provider.reserve_ip(reservation)
            saved_address = Bosh::Director::Models::IpAddress.first
            expect(saved_address.static).to eq(false)
          end
        end

        context 'when IP belongs to static pool' do
          before { reservation.resolve_ip('192.168.0.2') }

          it 'raises an error' do
            expect {
              ip_provider.reserve_ip(reservation)
            }.to raise_error BD::NetworkReservationWrongType
          end
        end
      end

      context 'when reserving static ip' do
        context 'when IP belongs to static pool' do
          let(:reservation) { BD::StaticNetworkReservation.new(instance, network, '192.168.0.2') }

          it 'saves IP as static' do
            ip_provider.reserve_ip(reservation)
            saved_address = Bosh::Director::Models::IpAddress.first
            expect(saved_address.static).to eq(true)
          end
        end

        context 'ip belongs to dynamic pool' do
          let(:reservation) { BD::StaticNetworkReservation.new(instance, network, '192.168.0.5') }

          it 'raises an error' do
            expect {
              ip_provider.reserve_ip(reservation)
            }.to raise_error BD::NetworkReservationWrongType
          end
        end
      end

      context 'when attempting to reserve a reserved ip' do
        context 'when IP is reserved by the same instance' do
          it 'succeeds' do
            expect { ip_provider.reserve_ip(reservation) }.to_not raise_error
            expect { ip_provider.reserve_ip(reservation) }.to_not raise_error
          end

          context 'when IP reservation type was changed' do
            def dynamic_reservation_bound_to_existing_with_ip(ip)
              dynamic_reservation = BD::DynamicNetworkReservation.new(instance, network)
              existing_reservation = BD::ExistingNetworkReservation.new(instance, network, cidr_ip(ip))
              existing_reservation.mark_reserved_as(BD::DynamicNetworkReservation)
              dynamic_reservation.bind_existing(existing_reservation)

              dynamic_reservation
            end

            let(:ip_provider_without_static_range) do
              DatabaseIpProvider.new(
                range,
                'fake-network',
                restricted_ips,
                Set.new,
                logger
              )
            end

            context 'from static to dynamic' do
              it 'updates IP type' do
                static_reservation = BD::StaticNetworkReservation.new(instance, network, cidr_ip('192.168.0.2'))
                ip_provider.reserve_ip(static_reservation)

                expect(Bosh::Director::Models::IpAddress.count).to eq(1)
                original_address = Bosh::Director::Models::IpAddress.first
                expect(original_address.static).to eq(true)

                dynamic_reservation = dynamic_reservation_bound_to_existing_with_ip('192.168.0.2')
                ip_provider_without_static_range.reserve_ip(dynamic_reservation)

                expect(Bosh::Director::Models::IpAddress.count).to eq(1)
                new_address = Bosh::Director::Models::IpAddress.first
                expect(new_address.static).to eq(false)
                expect(new_address.address).to eq(original_address.address)
              end
            end

            context 'from dynamic to static' do
              it 'updates IP type' do
                dynamic_reservation = dynamic_reservation_bound_to_existing_with_ip('192.168.0.2')
                ip_provider_without_static_range.reserve_ip(dynamic_reservation)

                expect(Bosh::Director::Models::IpAddress.count).to eq(1)
                original_address = Bosh::Director::Models::IpAddress.first
                expect(original_address.static).to eq(false)

                static_reservation = BD::StaticNetworkReservation.new(instance, network, cidr_ip('192.168.0.2'))
                ip_provider.reserve_ip(static_reservation)

                expect(Bosh::Director::Models::IpAddress.count).to eq(1)
                new_address = Bosh::Director::Models::IpAddress.first
                expect(new_address.static).to eq(true)
                expect(new_address.address).to eq(original_address.address)
              end
            end

            context 'reusing existing dynamic reservation as static' do
              it 'updates IP type' do
                dynamic_reservation = dynamic_reservation_bound_to_existing_with_ip('192.168.0.2')
                ip_provider_without_static_range.reserve_ip(dynamic_reservation)

                expect(Bosh::Director::Models::IpAddress.count).to eq(1)
                original_address = Bosh::Director::Models::IpAddress.first
                expect(original_address.static).to eq(false)

                existing_reservation = BD::ExistingNetworkReservation.new(instance, network, cidr_ip('192.168.0.2'))
                ip_provider.reserve_ip(existing_reservation)

                expect(Bosh::Director::Models::IpAddress.count).to eq(1)
                new_address = Bosh::Director::Models::IpAddress.first
                expect(new_address.static).to eq(true)
                expect(new_address.address).to eq(original_address.address)
              end
            end
          end
        end

        context 'when IP is reserved by different instance' do
          let(:another_instance) do
            instance_double(
              Instance,
              model: Bosh::Director::Models::Instance.make(
                job: 'another-job',
                index: 5,
                deployment: Bosh::Director::Models::Deployment.make(name: 'fake-deployment')
              )
            )
          end

          it 'raises an error' do
            ip_provider.reserve_ip(BD::StaticNetworkReservation.new(another_instance, network, '192.168.0.2'))

            expect {
              ip_provider.reserve_ip(BD::StaticNetworkReservation.new(instance, network, '192.168.0.2'))
            }.to raise_error Bosh::Director::NetworkReservationAlreadyInUse,
              "Failed to reserve IP '192.168.0.2' for instance 'fake-job/0': " +
              "already reserved by instance 'another-job/5' from deployment 'fake-deployment'"
          end
        end

        context 'when IP is released by another deployment' do
          it 'retries to reserve it' do
            allow_any_instance_of(Bosh::Director::Models::IpAddress).to receive(:save) do
              allow_any_instance_of(Bosh::Director::Models::IpAddress).to receive(:save).and_call_original

              raise Sequel::ValidationFailed.new('address and network_name unique')
            end

            ip_provider.reserve_ip(reservation)

            saved_address = Bosh::Director::Models::IpAddress.order(:address).last
            expect(saved_address.address).to eq(cidr_ip('192.168.0.2'))
            expect(saved_address.network_name).to eq('fake-network')
            expect(saved_address.task_id).to eq('fake-task-id')
            expect(saved_address.created_at).to_not be_nil
          end
        end
      end

      context 'when reserving ip from restricted_ips list' do
        let(:restricted_ips) do
          Set.new [
              cidr_ip('192.168.0.2'),
            ]
        end

        context 'when existing network reservation' do
          it 'raises an error' do
            reservation = BD::ExistingNetworkReservation.new(instance, network, cidr_ip('192.168.0.2'))
            expect {
              ip_provider.reserve_ip(reservation)
            }.to_not raise_error
          end
        end

        context 'when static network reservation' do
          it 'raises an error' do
            reservation = BD::StaticNetworkReservation.new(instance, network, cidr_ip('192.168.0.2'))
            expect {
              ip_provider.reserve_ip(reservation)
            }.to raise_error Bosh::Director::NetworkReservationIpReserved,
                "Failed to reserve IP '192.168.0.2' for network 'fake-network': IP belongs to reserved range"
          end
        end

        context 'when dynamic network reservation' do
          it 'raises an error' do
            reservation =  BD::DynamicNetworkReservation.new(instance, network)
            reservation.resolve_ip(cidr_ip('192.168.0.2'))
            expect {
              ip_provider.reserve_ip(reservation)
            }.to raise_error Bosh::Director::NetworkReservationIpReserved,
                "Failed to reserve IP '192.168.0.2' for network 'fake-network': IP belongs to reserved range"
          end
        end
      end
    end
  end
end