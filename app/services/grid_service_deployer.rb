require 'celluloid'
require_relative 'grid_scheduler'

class GridServiceDeployer
  include Celluloid

  attr_reader :grid_service, :nodes, :scheduler

  ##
  # @param [#find_node] strategy
  # @param [GridService] grid_service
  # @param [Array<HostNode>] nodes
  def initialize(strategy, grid_service, nodes)
    @scheduler = GridScheduler.new(strategy)
    @grid_service = grid_service
    @nodes = nodes
  end


  ##
  # Is deploy possible?
  #
  # @return [Boolean]
  def can_deploy?
    self.grid_service.container_count.times do |i|
      container_name = "#{self.grid_service.name}-#{i + 1}"
      node = self.scheduler.select_node(self.grid_service, container_name, self.nodes)
      return false unless node
    end

    true
  end

  ##
  # @param [Hash] creds
  def deploy(creds = nil)
    prev_state = self.grid_service.state
    self.grid_service.update_attribute(:state, 'deploying')

    pulled_nodes = Set.new
    deploy_rev = Time.now.utc.to_s
    self.grid_service.container_count.times do |i|
      container_name = "#{self.grid_service.name}-#{i + 1}"
      node = self.scheduler.select_node(self.grid_service, container_name, self.nodes)

      raise "Cannot find applicable node for container: #{container_name}" unless node

      unless pulled_nodes.include?(node)
        self.ensure_image(node, self.grid_service.image_name, creds)
        pulled_nodes << node
      end
      self.deploy_service_container(node, container_name, deploy_rev)
    end

    self.grid_service.containers.where(:deploy_rev => {:$ne => deploy_rev}).each do |container|
      self.remove_service_container(container)
    end
    self.grid_service.update_attribute(:state, 'running')

    true
  rescue RpcClient::Error => exc
    self.grid_service.update_attribute(:state, prev_state)

    raise exc
  rescue => exc
    self.grid_service.update_attribute(:state, prev_state)
    raise exc
  end

  ##
  # @param [HostNode] node
  # @param [String] image_name
  # @param [Hash] creds
  def ensure_image(node, image_name, creds = nil)
    image = image_puller(node, creds).pull_image(image_name)
    self.grid_service.update_attribute(:image_id, image.id)
  end

  ##
  # @param [HostNode] node
  # @param [Hash] creds
  def image_puller(node, creds = nil)
    Docker::ImagePuller.new(node, creds)
  end

  ##
  # @param [HostNode] node
  # @param [String] container_name
  # @param [String] deploy_rev
  def deploy_service_container(node, container_name, deploy_rev)
    old_container = self.grid_service.container_by_name(container_name)
    if old_container && old_container.exists_on_node?
      self.remove_service_container(old_container)
    end
    container = self.create_service_container(node, container_name, deploy_rev)
    self.start_service_container(container)
    Timeout.timeout(20) do
      sleep 0.5 until container_running?(container)
    end
  end

  ##
  # @param [HostNode] node
  # @param [String] container_name
  # @return [Container]
  def create_service_container(node, container_name, deploy_rev)
    creator = Docker::ContainerCreator.new(self.grid_service, node)
    creator.create_container(container_name, deploy_rev)
  end

  ##
  # @param [Container] container
  def start_service_container(container)
    starter = Docker::ContainerStarter.new(container)
    starter.start_container
  end

  ##
  # @param [Container] container
  def remove_service_container(container)
    Docker::ContainerRemover.new(container).remove_container
  end

  ##
  # @param [Container] container
  # @return [Boolean]
  def container_running?(container)
    container.reload.running?
  end
end