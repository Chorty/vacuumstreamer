#!/usr/bin/env python3
"""
Phase 7: Update drive scripts in scripts.yaml to use dynamic speed from input_number.
Also add toggle scripts for obstacle images/avoidance/child lock.
"""
import sys

def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else '/config/scripts.yaml'
    
    with open(config_path, 'r') as f:
        content = f.read()
    
    # Replace all 4 drive scripts with dynamic speed versions
    old_drive_forward = """vacuum_drive_forward:
  alias: Vacuum Drive Forward
  icon: mdi:arrow-up-bold
  sequence:
    - action: rest_command.vacuum_drive_move
      data:
        velocity: "0.5"
        angle: "0\""""
    
    new_drive_forward = """vacuum_drive_forward:
  alias: Vacuum Drive Forward
  icon: mdi:arrow-up-bold
  sequence:
    - action: rest_command.vacuum_drive_move
      data:
        velocity: "{{ states('input_number.vacuum_drive_speed') | float(50) / 100 }}"
        angle: "0\""""
    
    old_drive_backward = """vacuum_drive_backward:
  alias: Vacuum Drive Backward
  icon: mdi:arrow-down-bold
  sequence:
    - action: rest_command.vacuum_drive_move
      data:
        velocity: "-0.5"
        angle: "0\""""
    
    new_drive_backward = """vacuum_drive_backward:
  alias: Vacuum Drive Backward
  icon: mdi:arrow-down-bold
  sequence:
    - action: rest_command.vacuum_drive_move
      data:
        velocity: "{{ (states('input_number.vacuum_drive_speed') | float(50) / 100) * -1 }}"
        angle: "0\""""
    
    old_drive_left = """vacuum_drive_left:
  alias: Vacuum Drive Left
  icon: mdi:arrow-left-bold
  sequence:
    - action: rest_command.vacuum_drive_move
      data:
        velocity: "0"
        angle: "90\""""
    
    new_drive_left = """vacuum_drive_left:
  alias: Vacuum Drive Left
  icon: mdi:arrow-left-bold
  sequence:
    - action: rest_command.vacuum_drive_move
      data:
        velocity: "0"
        angle: "{{ (states('input_number.vacuum_drive_speed') | float(50) / 100 * 180) * -1 }}""""
    
    old_drive_right = """vacuum_drive_right:
  alias: Vacuum Drive Right
  icon: mdi:arrow-right-bold
  sequence:
    - action: rest_command.vacuum_drive_move
      data:
        velocity: "0"
        angle: "-90\""""
    
    new_drive_right = """vacuum_drive_right:
  alias: Vacuum Drive Right
  icon: mdi:arrow-right-bold
  sequence:
    - action: rest_command.vacuum_drive_move
      data:
        velocity: "0"
        angle: "{{ states('input_number.vacuum_drive_speed') | float(50) / 100 * 180 }}""""
    
    content = content.replace(old_drive_forward, new_drive_forward)
    content = content.replace(old_drive_backward, new_drive_backward)
    content = content.replace(old_drive_left, new_drive_left)
    content = content.replace(old_drive_right, new_drive_right)
    
    # Append new toggle scripts
    content += """
vacuum_toggle_obstacle_images:
  alias: Vacuum Toggle Obstacle Images
  icon: mdi:camera
  sequence:
    - choose:
        - conditions:
            - condition: state
              entity_id: sensor.vacuum_obstacle_images
              state: "True"
          sequence:
            - action: rest_command.vacuum_obstacle_images_disable
        - conditions:
            - condition: state
              entity_id: sensor.vacuum_obstacle_images
              state: "False"
          sequence:
            - action: rest_command.vacuum_obstacle_images_enable

vacuum_toggle_obstacle_avoidance:
  alias: Vacuum Toggle Obstacle Avoidance
  icon: mdi:shield-check
  sequence:
    - choose:
        - conditions:
            - condition: state
              entity_id: sensor.vacuum_obstacle_avoidance
              state: "True"
          sequence:
            - action: rest_command.vacuum_obstacle_avoidance_disable
        - conditions:
            - condition: state
              entity_id: sensor.vacuum_obstacle_avoidance
              state: "False"
          sequence:
            - action: rest_command.vacuum_obstacle_avoidance_enable

vacuum_toggle_child_lock:
  alias: Vacuum Toggle Child Lock
  icon: mdi:lock
  sequence:
    - choose:
        - conditions:
            - condition: state
              entity_id: sensor.vacuum_child_lock
              state: "True"
          sequence:
            - action: rest_command.vacuum_child_lock_disable
        - conditions:
            - condition: state
              entity_id: sensor.vacuum_child_lock
              state: "False"
          sequence:
            - action: rest_command.vacuum_child_lock_enable
"""
    
    with open(config_path, 'w') as f:
        f.write(content)
    
    print(f"Updated {config_path}")
    print("Updated: 4 drive scripts with dynamic speed")
    print("Added: 3 toggle scripts (obstacle_images, obstacle_avoidance, child_lock)")

if __name__ == '__main__':
    main()
