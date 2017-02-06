module Profiler
  #Perform analysis on the collected profile information
  #
  # Note: if profiling an embedded mruby instance be aware that the execution
  #       time of the return instruction leaving the mruby VM will be
  #       overestimated
  def self.analyze
      analyze_normal
      #analyze_kcached
  end

  #Produce a kcachegrind compatiable output to STDOUT
  #
  #Note: There appears to be some issue in the output including:
  #      1. Multiple traces of the same method (with different callstacks)
  #      2. Incorrect estimates of cumulative call costs (see lines after
  #         'calls='
  #      3. Multiple methods using the same IREP sequence (it's unclear if mruby
  #         is mapping different methods to the same IREP instance if the locals
  #         and VM code sequence is the same. If it is, then IREP pointers are
  #         no longer a valid UUID for a method call).
  def self.analyze_kcached
    ireps = {}
    ireps2 = {}
    print("version: 1\n")
    print("positions: instr\n")
    print("events: ticks\n")
    virtuals = []

    #Build map of irep addresses to alias numbers
    irep_num.times do |ino|
      insir = get_irep_info(ino)
      id    = insir[0]
      meth  = "#{insir[1]}##{insir[2]}"
      if(ireps.include?(id))
        if(ireps2[id] == meth)
          #puts "duplicate address?"
        else
          #puts "duplicate and invalid address?"
          virtuals << meth
        end
      end
      ireps[id] = ino
      ireps2[id] = meth
      print("fl=(#{ino}) #{insir[3]}\n") if insir[3]
      print("fn=(#{ino}) #{insir[1]}##{insir[2]}\n")
    end

    irep_num.times do |ino|
      insir = get_irep_info(ino)
      irepno = ireps[insir[0]]
      print("fl=(#{irepno}) #{insir[3]}\n") if insir[3]
      print("fn=(#{irepno}) #{insir[1]}##{insir[2]}\n")

      ilen(ino).times do |ioff|
        insin = get_inst_info(ino, ioff)
        next if (insin[3] * 10000000).to_i == 0
        print("#{insir[0]} #{(insin[3] * 10000000).to_i}\n")
      end

      childs = insir[4]
      ccalls = insir[5]
      childs.size.times do |cno|
        ch_irepno = ireps[childs[cno]]
        next if(ch_irepno.nil?)
        ch_irep = get_irep_info(ch_irepno)
        print("cfl=(#{ch_irepno}) #{ch_irep[3]}\n") if ch_irep[3]
        print("cfn=(#{ch_irepno}) #{ch_irep[1]}##{ch_irep[2]}\n")
        print("calls=#{ccalls[cno]} +1\n")
        print("#{ch_irep[0]} 1000\n")
        #print("1 1000\n")
      end
    end
  end

  #Display normal mixed source level/VM level analysis of traced results
  #
  #The default format is:
  #
  #LINE TIME_SECONDS SOURCE_LINE
  #     NUM_EXECUTIONS TIME_SECONDS DECODED_VM_INSTRUCTION
  def self.analyze_normal

    #Known source
    files = {}
    #Methods without corresponding source
    nosrc = {}

    #Time spent in individual instructions
    #Used in summary
    itimes = []

    #Map method/instruction level info to:
    # - file+line                    OR
    # - method+instruction offset
    total_time = 0.0
    irep_num.times do |ino|
      fn = get_inst_info(ino, 0)[0]
      if fn.is_a?(String) then
        files[fn] ||= {}
        ilen(ino).times do |ioff|
          info   = get_inst_info(ino, ioff)
          total_time += info[3]
          lineno = info[1]
          if lineno then
            files[fn][lineno] ||= []
            files[fn][lineno].push info
          end
        end
      else
        mname = "#{fn[0]}##{fn[1]}"
        ilen(ino).times do |ioff|
          info = get_inst_info(ino, ioff)
          total_time += info[3]
          nosrc[mname] ||= []
          nosrc[mname].push info
        end
      end
    end

    #Print stats for each line and disassembled VM instructions
    #which correspond to each line
    files.each do |fn, infos|
      lines = read(fn)
      lines.each_with_index do |lin, i|
        num = 0
        time = 0.0
        if infos[i + 1] then
          infos[i + 1].each do |info|
            time += info[3]
            if num < info[2] then
              num = info[2]
            end
          end
        end

        #   Execute Count
        #        print(sprintf("%04d %10d %s", i, num, lin))

        #   Execute Time
        print(sprintf("%04d %7.5f %s", i, time, lin))

        #   Execute Time per 1 instruction
        #        if num != 0 then
        #          print(sprintf("%04d %4.5f %s", i, time / num, lin))
        #        else
        #          print(sprintf("%04d %4.5f %s", i, 0.0, lin))
        #        end
        if infos[i + 1] then
          codes = {}
          infos[i + 1].each do |info|
            codes[info[4]] ||= [nil, 0, 0.0]
            codes[info[4]][0] = info[5]
            codes[info[4]][1] += info[2]
            codes[info[4]][2] += info[3]
          end

          codes.each do |val|
            code = val[1][0]
            num = val[1][1]
            time = val[1][2]
            printf("            %10d %-7.5f    %s \n" , num, time, code)
            itimes << time if time > 1e-6
          end
        end
      end
    end

    #Dump stats for lines without any source level information
    nosrc.each do |mn, infos|
      codes = {}
      method_time = 0.0
      infos.each do |info|
        codes[info[4]] ||= [nil, 0, 0.0]
        codes[info[4]][0] = info[5]
        codes[info[4]][1] += info[2]
        codes[info[4]][2] += info[3]
        method_time += info[3]
      end

      printf("%s %-7.5f\n", mn, method_time)
      codes.each do |val|
        code = val[1][0]
        num  = val[1][1]
        time = val[1][2]
        printf("            %10d %-7.5f    %s \n" , num, time, code)
        itimes << time if time > 1e-6
      end
    end
    print("Total recorded time = #{total_time} seconds\n")
    begin
      itimes = itimes.sort.reverse
      pr50   = total_time*0.50
      pr90   = total_time*0.90
      pr95   = total_time*0.95
      cum    = 0.0
      itimes.each_with_index do |t, idx|
        cum += t
        if(cum > pr50)
          print("50% of execution in #{idx+1} VM instructions (above #{t*1000} ms each)\n")
          pr50 = total_time
        end
        if(cum > pr90)
          print("90% of execution in #{idx+1} VM instructions (above #{t*1000} ms each)\n")
          pr90 = total_time
        end
        if(cum > pr95)
          print("95% of execution in #{idx+1} VM instructions (above #{t*1000} ms each)\n")
          break
        end
      end
    end
  end
end
