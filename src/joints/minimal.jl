################################################################################
# Coordinates
################################################################################
function minimal_coordinates(joint::JointConstraint, pbody::Node, cbody::Node)
	Δx = minimal_coordinates(joint.translational, current_configuration(pbody.state)..., current_configuration(cbody.state)...)
    Δθ = minimal_coordinates(joint.rotational,    current_configuration(pbody.state)..., current_configuration(cbody.state)...)
	return [Δx; Δθ]
end

function set_minimal_coordinates!(joint::JointConstraint, pnode::Node, cnode::Node,
        timestep;
        Δx::AbstractVector=szeros(input_dimension(joint.translational)),
        Δθ::AbstractVector=szeros(input_dimension(joint.rotational)))

    set_minimal_coordinates!(joint.rotational,    pnode, cnode, timestep; Δθ=Δθ)
    set_minimal_coordinates!(joint.translational, pnode, cnode, timestep; Δx=Δx)

    return nothing
end

function set_minimal_coordinates!(mechanism, joint::JointConstraint{T,N,Nc}, xθ; iter=true) where {T,N,Nc}
    # bodies
    pbody = get_body(mechanism, joint.parent_id)
    cbody = get_body(mechanism, joint.child_id)

    # unpack
    Δx = xθ[SUnitRange(joint.minimal_index[1][1], joint.minimal_index[1][2])]
    Δθ = xθ[SUnitRange(joint.minimal_index[2][1], joint.minimal_index[2][2])]

    # set
    set_minimal_coordinates!(joint, pbody, cbody, mechanism.timestep, Δx=Δx, Δθ=Δθ)

    # recursive update down the kinematic chain
    if iter
        current = get_minimal_coordinates(mechanism)
        for id in recursivedirectchildren!(mechanism.system, joint.id)
            node = get_node(mechanism, id)
            if node isa JointConstraint
                set_minimal_coordinates!(mechanism, node, current[id])
            end
        end
    end
end

################################################################################
# Velocities
################################################################################
function minimal_velocities(joint::JointConstraint, pnode::Node, cnode::Node, timestep)
    Δv = minimal_velocities(joint.translational, pnode, cnode, timestep)
    Δϕ = minimal_velocities(joint.rotational,    pnode, cnode, timestep)
    return [Δv; Δϕ]
end

function set_minimal_velocities!(joint::JointConstraint, pnode::Node, cnode::Node, timestep;
        Δv=szeros(input_dimension(joint.translational)),
        Δϕ=szeros(input_dimension(joint.rotational)))

    # get
	vb, ϕb = get_child_velocity(joint,
        initial_configuration_velocity(pnode.state)...,
	 	current_configuration(cnode.state)...,
        timestep,
        Δv=Δv, Δϕ=Δϕ)

    # set
	set_maximal_velocities!(cnode; v=vb, ω=ϕb)
	set_previous_configuration!(cnode, timestep)

    return nothing
end

function set_minimal_velocities!(mechanism, joint::JointConstraint{T,N,Nc}, vϕ) where {T,N,Nc}
    # bodies
    pbody = get_body(mechanism, joint.parent_id)
    cbody = get_body(mechanism, joint.child_id)

    # unpack
    Δv = vϕ[SUnitRange(joint.minimal_index[1][1], joint.minimal_index[1][2])]
    Δϕ = vϕ[SUnitRange(joint.minimal_index[2][1], joint.minimal_index[2][2])]

    # set
    set_minimal_velocities!(joint, pbody, cbody, mechanism.timestep, Δv=Δv, Δϕ=Δϕ)
    return
end

function get_child_velocity(joint::JointConstraint,
    xa::AbstractVector, va::AbstractVector, qa::Quaternion, ϕa::AbstractVector,
    xb::AbstractVector, qb::Quaternion,
    timestep;
    Δv=szeros(input_dimension(joint.translational)),
    Δϕ=szeros(input_dimension(joint.rotational)))

    rot = joint.rotational
    tra = joint.translational
    pa = tra.vertices[1]
    pb = tra.vertices[2]
    axis_offset = rot.axis_offset
    Arot = zerodimstaticadjoint(nullspace_mask(rot))
    Atra = zerodimstaticadjoint(nullspace_mask(tra))

    Δx = minimal_coordinates(joint.translational, xa, qa, xb, qb)
    Δq = inv(axis_offset) * inv(qa) * qb

    # 1 step backward in time
    xa1 = next_position(xa, -va, timestep)
    qa1 = next_orientation(qa, -ϕa, timestep)

    # Finite difference
    Δx1 = Δx .- Δv * timestep
    Δq1 = Δq * inv(axis_angle_to_quaternion(Arot * Δϕ * timestep))

    qb1 = qa1 * axis_offset * Δq1
    xb1 = xa1 + vector_rotate(pa + Atra * Δx1, qa1) - vector_rotate(pb, qb1)

    # Finite difference
    vb = (xb - xb1) / timestep
    ϕb = angular_velocity(qb1, qb, timestep)

    return vb, ϕb
end

################################################################################
# Coordinates and Velocities
################################################################################
function minimal_coordinates_velocities(joint::JointConstraint, pnode::Node, cnode::Node, timestep)
    Δxθ = minimal_coordinates(joint, pnode, cnode)
    Δvϕ = minimal_velocities(joint, pnode, cnode, timestep)
    return [Δxθ; Δvϕ]
end

function set_minimal_coordinates_velocities!(mechanism::Mechanism, joint::JointConstraint;
        xmin::AbstractVector=szeros(2*input_dimension(joint)))

    pnode = get_body(mechanism, joint.parent_id)
    cnode = get_body(mechanism, joint.child_id)

    xa = pnode.state.x2
    va = pnode.state.v15
    qa = pnode.state.q2
    ϕa = pnode.state.ϕ15

    za = [xa; va; vector(qa); ϕa]

    set_minimal_coordinates_velocities!(joint, pnode, cnode, mechanism.timestep; xmin=xmin, zp=za)
end

function set_minimal_coordinates_velocities!(joint::JointConstraint,
        pbody::Node, cbody::Node,
        timestep;
        zp::AbstractVector=[pbody.state.x2; pbody.state.v15; vector(pbody.state.q2); pbody.state.ϕ15],
        xmin::AbstractVector=szeros(2*input_dimension(joint)))

    nu = input_dimension(joint)

    Δx = xmin[SUnitRange(joint.minimal_index[1]...)]
    Δθ = xmin[SUnitRange(joint.minimal_index[2]...)]

    Δv = xmin[nu .+ SUnitRange(joint.minimal_index[1]...)]
    Δϕ = xmin[nu .+ SUnitRange(joint.minimal_index[2]...)]

    rot = joint.rotational
    tra = joint.translational
    pa = tra.vertices[1]
    pb = tra.vertices[2]
    axis_offset = rot.axis_offset
    Arot = zerodimstaticadjoint(nullspace_mask(rot))
    Atra = zerodimstaticadjoint(nullspace_mask(tra))

    # parent state
    xa = SVector{3}(zp[1:3])
    va = SVector{3}(zp[3 .+ (1:3)])
    qa = Quaternion(zp[6 .+ (1:4)]...)
    ϕa = SVector{3}(zp[10 .+ (1:3)])

    # positions
    Δq = axis_angle_to_quaternion(Arot * Δθ)
	qb = qa * axis_offset * Δq
    xb = xa + vector_rotate(pa + Atra * Δx, qa) - vector_rotate(pb, qb)

    # previous configuration
    xa1 = next_position(xa, -va, timestep)
    qa1 = next_orientation(qa, -ϕa, timestep)

    # finite-difference configuration
    Δx1 = Δx .- Δv * timestep
    Δq1 = Δq * inv(axis_angle_to_quaternion(Arot * Δϕ * timestep))

    qb1 = qa1 * axis_offset * Δq1
    xb1 = xa1 + vector_rotate(pa + Atra * Δx1, qa1) - vector_rotate(pb, qb1)

    # finite-difference velocity
    vb = (xb - xb1) / timestep
    ϕb = angular_velocity(qb1, qb, timestep)

    # set child state
    cbody.state.x2 = xb
    cbody.state.v15 = vb
    cbody.state.q2 = qb
    cbody.state.ϕ15 = ϕb

    return [xb; vb; vector(qb); ϕb]
end

function minimal_coordinates_velocities_jacobian_parent(joint::JointConstraint{T},
    xa::AbstractVector, va::AbstractVector, qa::Quaternion, ϕa::AbstractVector,
    timestep;
    Δx=szeros(input_dimension(joint.translational)),
    Δθ=szeros(input_dimension(joint.rotational)),
    Δv=szeros(input_dimension(joint.translational)),
    Δϕ=szeros(input_dimension(joint.rotational))) where T

    rot = joint.rotational
    tra = joint.translational
    pa = tra.vertices[1]
    pb = tra.vertices[2]
    axis_offset = rot.axis_offset
    Arot = zerodimstaticadjoint(nullspace_mask(rot))
    Atra = zerodimstaticadjoint(nullspace_mask(tra))

    # positions
    Δq = axis_angle_to_quaternion(Arot * Δθ)
	qb = qa * axis_offset * Δq
    xb = xa + vector_rotate(pa + Atra * Δx, qa) - vector_rotate(pb, qb)

    # step backward in time
    xa1 = next_position(xa, -va, timestep)
    qa1 = next_orientation(qa, -ϕa, timestep)

    # step backward in time
    Δx1 = Δx .- Δv * timestep
    Δq1 = Δq * inv(axis_angle_to_quaternion(Arot * Δϕ * timestep))

    qb1 = qa1 * axis_offset * Δq1
    xb1 = xa1 + vector_rotate(pa + Atra * Δx1, qa1) - vector_rotate(pb, qb1)

    # Jacobians

    ∂xb∂xa = 1.0 * I(3)

    ∂xb∂va = szeros(T, 3, 3)

    ∂xb∂qa = ∂vector_rotate∂q(pa + Atra * Δx, qa)
    ∂xb∂qa += -∂vector_rotate∂q(pb, qb) * Rmat(axis_offset * axis_angle_to_quaternion(Arot * Δθ))

    ∂xb∂ϕa = szeros(T, 3, 3)

    ∂qb∂xa = szeros(T, 4, 3)

    ∂qb∂va = szeros(T, 4, 3)

    ∂qb∂qa = Rmat(axis_offset * axis_angle_to_quaternion(Arot * Δθ))

    ∂qb∂ϕa = szeros(T, 4, 3)

    ∂vb∂xa = szeros(T, 3, 3)

    ∂vb∂va = 1.0 * I(3)

    ∂vb∂qa = 1.0 / timestep * ∂vector_rotate∂q(pa + Atra * Δx, qa)
    ∂vb∂qa -= 1.0 / timestep * ∂vector_rotate∂q(pb, qb) * Rmat(axis_offset * Δq)
    ∂vb∂qa += -1.0 / timestep * ∂vector_rotate∂q(pa + Atra * Δx1, qa1) * rotational_integrator_jacobian_orientation(qa, -ϕa, timestep, attjac=false)
    ∂vb∂qa += 1.0 / timestep * ∂vector_rotate∂q(pb, qb1) * Rmat(axis_offset * Δq1) * rotational_integrator_jacobian_orientation(qa, -ϕa, timestep, attjac=false)

    ∂vb∂ϕa = 1.0 / timestep * ∂vector_rotate∂q(pa + Atra * Δx1, qa1) * rotational_integrator_jacobian_velocity(qa, -ϕa, timestep)
    ∂vb∂ϕa += -1.0 / timestep * ∂vector_rotate∂q(pb, qb1) * Rmat(axis_offset * Δq1) * rotational_integrator_jacobian_velocity(qa, -ϕa, timestep)

    ∂ϕb∂xa = szeros(T, 3, 3)

    ∂ϕb∂va = szeros(T, 3, 3)

    ∂ϕb∂qa = ∂angular_velocity∂q1(qb1, qb, timestep) * Rmat(axis_offset * Δq1) * rotational_integrator_jacobian_orientation(qa, -ϕa, timestep, attjac=false)
    ∂ϕb∂qa += ∂angular_velocity∂q2(qb1, qb, timestep) * Rmat(axis_offset * Δq)

    ∂ϕb∂ϕa = -1.0 * ∂angular_velocity∂q1(qb1, qb, timestep) * Rmat(axis_offset * Δq1) * rotational_integrator_jacobian_velocity(qa, -ϕa, timestep)

    [
        ∂xb∂xa ∂xb∂va ∂xb∂qa ∂xb∂ϕa;
        ∂vb∂xa ∂vb∂va ∂vb∂qa ∂vb∂ϕa;
        ∂qb∂xa ∂qb∂va ∂qb∂qa ∂qb∂ϕa;
        ∂ϕb∂xa ∂ϕb∂va ∂ϕb∂qa ∂ϕb∂ϕa;
    ]
end

function set_minimal_coordinates_velocities_jacobian_parent(joint::JointConstraint,
    pnode::Node, cnode::Node, timestep)

    xmin = minimal_coordinates_velocities(joint, pnode, cnode, timestep)
    qb = current_orientation(cnode.state)
    xa, va, qa, ϕa = initial_configuration_velocity(pnode.state)
    za = [xa; va; vector(qa); ϕa]

    nu = input_dimension(joint)
    Δx = xmin[SUnitRange(joint.minimal_index[1]...)]
    Δθ = xmin[SUnitRange(joint.minimal_index[2]...)]
    Δv = xmin[nu .+ SUnitRange(joint.minimal_index[1]...)]
    Δϕ = xmin[nu .+ SUnitRange(joint.minimal_index[2]...)]
    J = minimal_coordinates_velocities_jacobian_parent(joint,
                xa, va, qa, ϕa,
                timestep;
                Δx=Δx,
                Δθ=Δθ,
                Δv=Δv,
                Δϕ=Δϕ)
    J = cat(Diagonal(sones(6)), LVᵀmat(qb)', Diagonal(sones(3)), dims=(1,2)) * J
    J = J * cat(Diagonal(sones(6)), LVᵀmat(qa), Diagonal(sones(3)), dims=(1,2))
    return J
end

function minimal_coordinates_velocities_jacobian_minimal(joint::JointConstraint{T},
    xa::AbstractVector, va::AbstractVector, qa::Quaternion, ϕa::AbstractVector,
    timestep;
    Δx=szeros(input_dimension(joint.translational)),
    Δθ=szeros(input_dimension(joint.rotational)),
    Δv=szeros(input_dimension(joint.translational)),
    Δϕ=szeros(input_dimension(joint.rotational))) where T

    rot = joint.rotational
    tra = joint.translational
    pa = tra.vertices[1]
    pb = tra.vertices[2]
    axis_offset = rot.axis_offset
    Arot = zerodimstaticadjoint(nullspace_mask(rot))
    Atra = zerodimstaticadjoint(nullspace_mask(tra))

    # positions
    Δq = axis_angle_to_quaternion(Arot * Δθ)
	qb = qa * axis_offset * Δq
    xb = xa + vector_rotate(pa + Atra * Δx, qa) - vector_rotate(pb, qb)

    # step backward in time
    xa1 = next_position(xa, -va, timestep)
    qa1 = next_orientation(qa, -ϕa, timestep)

    # step backward in time
    Δq = axis_angle_to_quaternion(Arot * Δθ)
    Δx1 = Δx .- Δv * timestep
    Δq1 = Δq * inv(axis_angle_to_quaternion(Arot * Δϕ * timestep))

    qb1 = qa1 * axis_offset * Δq1
    xb1 = xa1 + vector_rotate(pa + Atra * Δx1, qa1) - vector_rotate(pb, qb1)

    # Jacobians
    ∂xb∂Δx = rotation_matrix(qa) * Atra
    ∂xb∂Δθ = -∂vector_rotate∂q(pb, qb) * Lmat(qa * axis_offset) * daxis_angle_to_quaterniondx(Arot * Δθ) * Arot
    ∂xb∂Δv = szeros(T, 3, input_dimension(joint.translational))
    ∂xb∂Δϕ = szeros(T, 3, input_dimension(joint.rotational))

    ∂qb∂Δx = szeros(T, 4, input_dimension(joint.translational))
    ∂qb∂Δθ = Lmat(qa * axis_offset) * daxis_angle_to_quaterniondx(Arot * Δθ) * Arot
    ∂qb∂Δv = szeros(T, 4, input_dimension(joint.translational))
    ∂qb∂Δϕ = szeros(T, 4, input_dimension(joint.rotational))

    ∂vb∂Δx = 1 / timestep * rotation_matrix(qa) * Atra
    ∂vb∂Δx += -1 / timestep * rotation_matrix(qa1) * Atra

    ∂vb∂Δθ = -1.0 / timestep * ∂vector_rotate∂q(pb, qb) * Lmat(qa * axis_offset) * daxis_angle_to_quaterniondx(Arot * Δθ) * Arot
    ∂vb∂Δθ += 1.0 / timestep * ∂vector_rotate∂q(pb, qb1) * Rmat(inv(axis_angle_to_quaternion(Arot * Δϕ * timestep))) * Lmat(qa1 * axis_offset) * daxis_angle_to_quaterniondx(Arot * Δθ) * Arot

    ∂vb∂Δv = rotation_matrix(qa1) * Atra

    ∂vb∂Δϕ = ∂vector_rotate∂q(pb, qb1) * Lmat(qa1 * axis_offset * Δq) * Tmat() * daxis_angle_to_quaterniondx(Arot * Δϕ * timestep) * Arot

    ∂ϕb∂Δx = szeros(T, 3, input_dimension(joint.translational))

    ∂ϕb∂Δθ = ∂angular_velocity∂q1(qb1, qb, timestep) * Rmat(inv(axis_angle_to_quaternion(Arot * Δϕ * timestep))) * Lmat(qa1 * axis_offset) * daxis_angle_to_quaterniondx(Arot * Δθ) * Arot
    ∂ϕb∂Δθ += ∂angular_velocity∂q2(qb1, qb, timestep) * Lmat(qa * axis_offset) * daxis_angle_to_quaterniondx(Arot * Δθ) * Arot

    ∂ϕb∂Δv = szeros(3, input_dimension(joint.translational))

    ∂ϕb∂Δϕ = ∂angular_velocity∂q1(qb1, qb, timestep) * Lmat(qa1 * axis_offset * Δq) * Tmat() * daxis_angle_to_quaterniondx(Arot * Δϕ * timestep) * Arot * timestep

    [
        ∂xb∂Δx ∂xb∂Δθ ∂xb∂Δv ∂xb∂Δϕ;
        ∂vb∂Δx ∂vb∂Δθ ∂vb∂Δv ∂vb∂Δϕ;
        ∂qb∂Δx ∂qb∂Δθ ∂qb∂Δv ∂qb∂Δϕ;
        ∂ϕb∂Δx ∂ϕb∂Δθ ∂ϕb∂Δv ∂ϕb∂Δϕ;
    ]
end

function set_minimal_coordinates_velocities_jacobian_minimal(joint::JointConstraint,
    pnode::Node, cnode::Node, timestep)

    xmin = minimal_coordinates_velocities(joint, pnode, cnode, timestep)
    qb = current_orientation(cnode.state)
    xa, va, qa, ϕa = initial_configuration_velocity(pnode.state)
    za = [xa; va; vector(qa); ϕa]

    nu = input_dimension(joint)
    Δx = xmin[SUnitRange(joint.minimal_index[1]...)]
    Δθ = xmin[SUnitRange(joint.minimal_index[2]...)]
    Δv = xmin[nu .+ SUnitRange(joint.minimal_index[1]...)]
    Δϕ = xmin[nu .+ SUnitRange(joint.minimal_index[2]...)]
    J = minimal_coordinates_velocities_jacobian_minimal(joint,
                xa, va, qa, ϕa,
                timestep;
                Δx=Δx,
                Δθ=Δθ,
                Δv=Δv,
                Δϕ=Δϕ)
    J = cat(Diagonal(sones(6)), LVᵀmat(qb)', Diagonal(sones(3)), dims=(1,2)) * J
    return J
end
