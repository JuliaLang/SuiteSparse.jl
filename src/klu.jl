module KLU

using SparseArrays
using SparseArrays: SparseMatrixCSC
import SparseArrays: nnz

import Base: (\), size, getproperty, setproperty!, propertynames, show
import ..increment, ..increment!, ..decrement, ..decrement!
import ..LibSuiteSparse:
    SuiteSparse_long,
    klu_l_common,
    klu_common,
    klu_l_defaults,
    klu_defaults,
    klu_l_symbolic,
    klu_symbolic,
    klu_l_free_symbolic,
    klu_free_symbolic,
    klu_l_numeric,
    klu_numeric,
    klu_l_free_numeric,
    klu_zl_free_numeric,
    klu_free_numeric,
    klu_z_free_numeric,
    KLU_OK,
    KLU_SINGULAR,
    KLU_OUT_OF_MEMORY,
    KLU_INVALID,
    KLU_TOO_LARGE,
    klu_l_analyze,
    klu_analyze,
    klu_l_factor,
    klu_factor,
    klu_zl_factor,
    klu_z_factor,
    klu_l_solve,
    klu_zl_solve,
    klu_solve,
    klu_z_solve,
    klu_l_tsolve,
    klu_zl_tsolve,
    klu_tsolve,
    klu_z_tsolve,
    klu_l_extract,
    klu_zl_extract,
    klu_extract,
    klu_z_extract,
    klu_l_sort,
    klu_zl_sort,
    klu_sort,
    klu_z_sort,
    klu_refactor,
    klu_z_refactor,
    klu_l_refactor,
    klu_zl_refactor
using LinearAlgebra
import LinearAlgebra: Factorization, issuccess, ldiv!
const KLUTypes = Union{Float64, ComplexF64}
const KLUValueTypes = (:Float64, :ComplexF64)
if sizeof(SuiteSparse_long) == 4
    const KLUITypes = Int32
    const KLUIndexTypes = (:Int32,)
else
    const KLUITypes = Union{Int32, Int64}
    const KLUIndexTypes = (:Int32, :Int64)
end

function kluerror(status::Integer)
    if status == KLU_OK
        return
    elseif status == KLU_SINGULAR
        throw(LinearAlgebra.SingularException(0))
    elseif status == KLU_OUT_OF_MEMORY
        throw(OutOfMemoryError())
    elseif status == KLU_INVALID
        throw(ArgumentError("Invalid Status"))
    elseif status == KLU_TOO_LARGE
        throw(OverflowError("Integer overflow has occured"))
    else
        throw(ErrorException("Unknown KLU error code: $status"))
    end
end

kluerror(common::Union{klu_l_common, klu_common}) = kluerror(common.status)

"""
Data structure for parameters of and statistics generated by KLU functions.

# Fields
- `tol::Float64`: Partial pivoting tolerance for diagonal preference
- `btf::Int64`: If `btf != 0` use BTF pre-ordering
- `ordering::Int64`: If `ordering == 0` use AMD to permute, if `ordering == 1` use COLAMD,
if `ordering == 3` use the user provided ordering function.
- `scale::Int64`: If `scale == 1` then `A[:,i] ./= sum(abs.(A[:,i]))`, if `scale == 2` then
`A[:,i] ./= maximum(abs.(A[:,i]))`. If `scale == 0` no scaling is done, and the input is
checked for errors if `scale >= 0`.

See the [KLU User Guide](https://github.com/DrTimothyAldenDavis/SuiteSparse/raw/master/KLU/Doc/KLU_UserGuide.pdf)
for more information.
"""
klu_l_common

"""
Data structure for parameters of and statistics generated by KLU functions.

This is the `Int32` version of [`klu_l_common`](@ref).
"""
klu_common

macro isok(A)
    :(kluerror($(esc(A))))
end

function _klu_name(name, Tv, Ti)
    outname = "klu_" * (Tv === :Float64 ? "" : "z") * (Ti === :Int64 ? "l_" : "_") * name
    return Symbol(replace(outname, "__"=>"_"))
end
function _common(T)
    if T == Int64
        common = klu_l_common()
        ok = klu_l_defaults(Ref(common))
    elseif T == Int32
        common = klu_common()
        ok = klu_defaults(Ref(common))
    else
        throw(ArgumentError("T must be Int64 or Int32"))
    end
    if ok == 1
        return common
    else
        throw(ErrorException("Could not initialize common struct."))
    end
end

"""
    KLUFactorization <: Factorization

Matrix factorization type of the KLU factorization of a sparse matrix `A`.
This is the return type of [`klu`](@ref), the corresponding matrix factorization function.

The factors can be obtained from `K::KLUFactorization` via `K.L`, `K.U` and `K.F`
See the [`klu`](@ref) docs for more information.

You typically should not construct this directly, instead use [`klu`](@ref).
"""
mutable struct KLUFactorization{Tv<:KLUTypes, Ti<:KLUITypes} <: Factorization{Tv}
    common::Union{klu_l_common, klu_common}
    _symbolic::Ptr{Cvoid}
    _numeric::Ptr{Cvoid}
    n::Int
    colptr::Vector{Ti}
    rowval::Vector{Ti}
    nzval::Vector{Tv}
    function KLUFactorization(n, colptr, rowval, nzval)
        Ti = eltype(colptr)
        Tv = eltype(nzval)
        common = _common(Ti)
        obj = new{Tv, Ti}(common, C_NULL, C_NULL, n, colptr, rowval, nzval)
        function f(klu)
            _free_symbolic(klu)
            _free_numeric(klu)
        end
        return finalizer(f, obj)
    end
end

function _free_symbolic(K::KLUFactorization{Tv, Ti}) where {Ti<:KLUITypes, Tv}
    if Ti == Int64
        klu_l_free_symbolic(Ref(Ptr{klu_l_symbolic}(K._symbolic)), Ref(K.common))
    elseif Ti == Int32
        klu_free_symbolic(Ref(Ptr{klu_symbolic}(K._symbolic)), Ref(K.common))
    end
    K._symbolic = C_NULL
end

for Ti ∈ KLUIndexTypes, Tv ∈ KLUValueTypes
    klufree = _klu_name("free_numeric", Tv, Ti)
    ptr = _klu_name("numeric", :Float64, Ti)
    @eval begin
        function _free_numeric(K::KLUFactorization{$Tv, $Ti})
            $klufree(Ref(Ptr{$ptr}(K._numeric)), Ref(K.common))
            K._numeric = C_NULL
        end
    end
end



function KLUFactorization(A::SparseMatrixCSC{Tv, Ti}) where {Tv<:KLUTypes, Ti<:KLUITypes}
    n = size(A, 1)
    n == size(A, 2) || throw(ArgumentError("KLU only accepts square matrices."))
    return KLUFactorization(n, decrement(A.colptr), decrement(A.rowval), A.nzval)
end

size(K::KLUFactorization) = (K.n, K.n)
function size(K::KLUFactorization, dim::Integer)
    if dim < 1
        throw(ArgumentError("size: dimension $dim out of range"))
    elseif dim == 1 || dim == 2
        return Int(K.n)
    else
        return 1
    end
end

nnz(K::KLUFactorization) = K.lnz + K.unz + K.nzoff

Base.adjoint(K::KLUFactorization) = Adjoint(K)
Base.transpose(K::KLUFactorization) = Transpose(K)

function setproperty!(klu::KLUFactorization, ::Val{:(_symbolic)}, x)
    _free_symbolic(klu)
    setfield!(klu, :(_symbolic), x)
end

function setproperty!(klu::KLUFactorization, ::Val{:(_numeric)}, x)
    _free_numeric(klu)
    setfield!(klu, :(_numeric), x)
end

# Certain sets of inputs must be non-null *together*:
# [Lp, Li, Lx], [Up, Ui, Ux], [Fp, Fi, Fx]
for Tv ∈ KLUValueTypes, Ti ∈ KLUIndexTypes
    extract = _klu_name("extract", Tv, Ti)
    sort = _klu_name("sort", Tv, Ti)
    if Tv === :ComplexF64
        call = :($extract(klu._numeric, klu._symbolic, Lp, Li, Lx, Lz, Up, Ui, Ux, Uz, Fp, Fi, Fx, Fz, P, Q, Rs, R, Ref(klu.common)))
    else
        call = :($extract(klu._numeric, klu._symbolic, Lp, Li, Lx, Up, Ui, Ux, Fp, Fi, Fx, P, Q, Rs, R, Ref(klu.common)))
    end
    @eval begin
        function _extract!(
            klu::KLUFactorization{$Tv, $Ti};
            Lp = C_NULL, Li = C_NULL, Up = C_NULL, Ui = C_NULL, Fp = C_NULL, Fi = C_NULL,
            P = C_NULL, Q = C_NULL, R = C_NULL, Lx = C_NULL, Lz = C_NULL, Ux = C_NULL, Uz = C_NULL,
            Fx = C_NULL, Fz = C_NULL, Rs = C_NULL
        )
            $sort(klu._symbolic, klu._numeric, Ref(klu.common))
            ok = $call
            if ok == 1
                return nothing
            else
                kluerror(klu.common)
            end
        end
    end
end

function Base.propertynames(::KLUFactorization, private::Bool=false)
    publicnames = (:lnz, :unz, :nzoff, :L, :U, :F, :q, :p, :Rs, :symbolic, :numeric,)
    privatenames = (:nblocks, :maxblock,  :(_L), :(_U), :(_F))
    if private
        return (publicnames..., privatenames...)
    else
        return publicnames
    end
end

function getproperty(klu::KLUFactorization{Tv, Ti}, s::Symbol) where {Tv<:KLUTypes, Ti<:KLUITypes}
    # Forwards to the numeric struct:
    if s ∈ [:lnz, :unz, :nzoff]
        klu._numeric == C_NULL && throw(ArgumentError("This KLUFactorization has not yet been factored. Try `klu_factor!`."))
        return getproperty(klu.numeric, s)
    end
    if s ∈ [:nblocks, :maxblock]
        klu._symbolic == C_NULL && throw(ArgumentError("This KLUFactorization has not yet been analyzed. Try `klu_analyze!`."))
        return getproperty(klu.symbolic, s)
    end
    if s === :symbolic
        klu._symbolic == C_NULL && throw(ArgumentError("This KLUFactorization has not yet been analyzed. Try `klu_analyze!`."))
        if Ti == Int64
            return unsafe_load(Ptr{klu_l_symbolic}(klu._symbolic))
        else
            return unsafe_load(Ptr{klu_symbolic}(klu._symbolic))
        end
    end
    if s === :numeric
        klu._numeric == C_NULL && throw(ArgumentError("This KLUFactorization has not yet been factored. Try `klu_factor!`."))
        if Ti == Int64
            return unsafe_load(Ptr{klu_l_numeric}(klu._numeric))
        else
            return unsafe_load(Ptr{klu_numeric}(klu._numeric))
        end
    end
    # Non-overloaded parts:
    if s ∉ [:L, :U, :F, :p, :q, :R, :Rs, :(_L), :(_U), :(_F)]
        return getfield(klu, s)
    end
    # Factor parts:
    if s === :(_L)
        lnz = klu.lnz
        Lp = Vector{Ti}(undef, klu.n + 1)
        Li = Vector{Ti}(undef, lnz)
        Lx = Vector{Float64}(undef, lnz)
        Lz = Tv == Float64 ? C_NULL : Vector{Float64}(undef, lnz)
        _extract!(klu; Lp, Li, Lx, Lz)
        return Lp, Li, Lx, Lz
    elseif s === :(_U)
        unz = klu.unz
        Up = Vector{Ti}(undef, klu.n + 1)
        Ui = Vector{Ti}(undef, unz)
        Ux = Vector{Float64}(undef, unz)
        Uz = Tv == Float64 ? C_NULL : Vector{Float64}(undef, unz)
        _extract!(klu; Up, Ui, Ux, Uz)
        return Up, Ui, Ux, Uz
    elseif s === :(_F)
        fnz = klu.nzoff
        # We often don't have an F, so create the right vectors for an empty SparseMatrixCSC
        if fnz == 0
            Fp = zeros(Ti, klu.n + 1)
            Fi = Vector{Ti}()
            Fx = Vector{Float64}()
            Fz = Tv == Float64 ? C_NULL : Vector{Float64}()
        else
            Fp = Vector{Ti}(undef, klu.n + 1)
            Fi = Vector{Ti}(undef, fnz)
            Fx = Vector{Float64}(undef, fnz)
            Fz = Tv == Float64 ? C_NULL : Vector{Float64}(undef, fnz)
            _extract!(klu; Fp, Fi, Fx, Fz)
            # F is *not* sorted on output, so we'll have to do it here:
            for i ∈ 1:length(Fp) - 1
                Fp[end] -= 1 # deal with last index being last + 1
                # find each segment
                first = Fp[i] + 1
                last = Fp[i+1] + 1
                # sort each column of rowval, nzval, and Fz for complex numbers if necessary
                #by the ascending permutation of rowval.
                Fiview = view(Fi, first:last)
                Fxview = view(Fx, first:last)
                P = sortperm(Fiview)
                Fiview .= Fiview[P]
                Fxview .= Fxview[P]
                if length(Fz) == length(Fx)
                    Fzview = view(Fz, first:last)
                    Fzview .= Fzview[P]
                end
                # reset the last entry
                Fp[end] += 1
            end
        end
        return Fp, Fi, Fx, Fz
    end
    if s ∈ [:q, :p, :R, :Rs]
        if s === :Rs
            out = Vector{Float64}(undef, klu.n)
        elseif s === :R
            out = Vector{Ti}(undef, klu.nblocks + 1)
        else
            out = Vector{Ti}(undef, klu.n)
        end
        # This tuple construction feels hacky, there's a better way I'm sure.
        s === :q && (s = :Q)
        s === :p && (s = :P)
        _extract!(klu; NamedTuple{(s,)}((out,))...)
        if s ∈ [:Q, :P, :R]
            increment!(out)
        end
        return out
    end
    if s ∈ [:L, :U, :F]
        if s === :L
            p, i, x, z = klu._L
        elseif s === :U
            p, i, x, z = klu._U
        elseif s === :F
            p, i, x, z = klu._F
        end
        if Tv == Float64
            return SparseMatrixCSC(klu.n, klu.n, increment!(p), increment!(i), x)
        else
            return SparseMatrixCSC(klu.n, klu.n, increment!(p), increment!(i), Complex.(x, z))
        end
    end
end

function LinearAlgebra.issuccess(K::KLUFactorization)
    return K.common.status == KLU_OK && K._numeric != C_NULL
end
function show(io::IO, mime::MIME{Symbol("text/plain")}, K::KLUFactorization)
    if issuccess(K)
        summary(io, K); println(io)
        println(io, "L factor:")
        show(io, mime, K.L)
        println(io, "\nU factor:")
        show(io, mime, K.U)
        F = K.F
        if F !== nothing
            println(io, "\nF factor:")
            show(io, mime, K.F)
        end
    else
        throw(ArgumentError("Failed factorization of type $(typeof(K)). Try `klu_factor!(K)`."))
    end
end

function klu_analyze!(K::KLUFactorization{Tv, Ti}) where {Tv, Ti<:KLUITypes}
    if K._symbolic != C_NULL return K end
    if Ti == Int64
        sym = klu_l_analyze(K.n, K.colptr, K.rowval, Ref(K.common))
    else
        sym = klu_analyze(K.n, K.colptr, K.rowval, Ref(K.common))
    end
    if sym == C_NULL
        kluerror(K.common)
    else
        K._symbolic = sym
    end
    return K
end

# User provided permutation vectors:
function klu_analyze!(K::KLUFactorization{Tv, Ti}, P::Vector{Ti}, Q::Vector{Ti}) where {Tv, Ti<:KLUITypes}
    if K._symbolic != C_NULL return K end
    if Ti == Int64
        sym = klu_l_analyze_given(K.n, K.colptr, K.rowval, P, Q, Ref(K.common))
    else
        sym = klu_analyze_given(K.n, K.colptr, K.rowval, P, Q, Ref(K.common))
    end
    if sym == C_NULL
        kluerror(K.common)
    else
        K._symbolic = sym
    end
    return K
end

for Tv ∈ KLUValueTypes, Ti ∈ KLUIndexTypes
    factor = _klu_name("factor", Tv, Ti)
    @eval begin
        function klu_factor!(K::KLUFactorization{$Tv, $Ti})
            K._symbolic == C_NULL  && klu_analyze!(K)
            num = $factor(K.colptr, K.rowval, K.nzval, K._symbolic, Ref(K.common))
            if num == C_NULL
                kluerror(K.common)
            else
                K._numeric = num
            end
            return K
        end
    end
end

"""
    klu_factor!(K::KLUFactorization)

Factor `K` into components `K.L`, `K.U`, and `K.F`.
This function will perform both the symbolic and numeric steps of factoriation on an
existing `KLUFactorization` instance.

The `K.common` struct can be used to modify certain options and parameters, see the
[KLU documentation](https://github.com/DrTimothyAldenDavis/SuiteSparse/raw/master/KLU/Doc/KLU_UserGuide.pdf)
or [`klu_common`](@ref) for more information.
"""
klu_factor!

"""
    klu(A::SparseMatrixCSC) -> K::KLUFactorization
    klu(n, colptr::Vector{Ti}, rowval::Vector{Ti}, nzval::Vector{Tv}) -> K::KLUFactorization

Compute the LU factorization of a sparse matrix `A` using KLU.

For sparse `A` with real or complex element type, the return type of `K` is
`KLUFactorization{Tv, Ti}`, with `Tv` = [`Float64`](@ref) or [`ComplexF64`](@ref)
respectively and `Ti` is an integer type ([`Int32`](@ref) or [`Int64`](@ref)).


The individual components of the factorization `K` can be accessed by indexing:

| Component | Description                                                      |
|:----------|:-----------------------------------------------------------------|
| `L`       | `L` (lower triangular) part of `LU` of the diagonal blocks       |
| `U`       | `U` (upper triangular) part of `LU` of the diagonal blocks       |
| `F`       | `F` (upper triangular) part of `LU + F`, the off-diagonal blocks |
| `p`       | right permutation `Vector`                                       |
| `q`       | left permutation `Vector`                                        |
| `Rs`      | `Vector` of scaling factors                                      |

The relation between `K` and `A` is

`K.L * K.U + K.F  == K.Rs [`\\`]`(@ref) A[K.p, K.q]`

`K` further supports the following functions:

- [`\\`](@ref)

!!! note
    `klu(A::SparseMatrixCSC)` uses the KLU library that is part of
    SuiteSparse. As this library only supports sparse matrices with [`Float64`](@ref) or
    `ComplexF64` elements, `lu` converts `A` into a copy that is of type
    `SparseMatrixCSC{Float64}` or `SparseMatrixCSC{ComplexF64}` as appropriate.
"""
function klu(n, colptr::Vector{Ti}, rowval::Vector{Ti}, nzval::Vector{Tv}) where {Ti<:KLUITypes, Tv<:AbstractFloat}
    if Tv != Float64
        nzval = convert(Vector{Float64}, nzval)
    end
    K = KLUFactorization(n, colptr, rowval, nzval)
    return klu_factor!(K)
end

function klu(n, colptr::Vector{Ti}, rowval::Vector{Ti}, nzval::Vector{Tv}) where {Ti<:KLUITypes, Tv<:Complex}
    if Tv != ComplexF64
        nzval = convert(Vector{ComplexF64}, nzval)
    end
    K = KLUFactorization(n, colptr, rowval, nzval)
    return klu_factor!(K)
end

function klu(A::SparseMatrixCSC{Tv, Ti}) where {Tv<:Union{AbstractFloat, Complex}, Ti<:KLUITypes}
    n = size(A, 1)
    n == size(A, 2) || throw(DimensionMismatch())
    return klu(n, decrement(A.colptr), decrement(A.rowval), A.nzval)
end

for Tv ∈ KLUValueTypes, Ti ∈ KLUIndexTypes
    refactor = _klu_name("refactor", Tv, Ti)
    @eval begin
        function klu!(K::KLUFactorization{$Tv, $Ti}, nzval::Vector{$Tv})
            length(nzval) != length(K.nzval)  && throw(DimensionMismatch())
            K.nzval = nzval
            ok = $refactor(K.colptr, K.rowval, K.nzval, K._symbolic, K._numeric, Ref(K.common))
            if ok == 1
                return K
            else
                kluerror(K.common)
            end
        end
    end
end

function klu!(K::KLUFactorization{ComplexF64}, nzval::Vector{U}) where {U<:Complex}
    return klu!(K, convert(Vector{ComplexF64}, nzval))
end

function klu!(K::KLUFactorization{Float64}, nzval::Vector{U}) where {U<:AbstractFloat}
    return klu!(K, convert(Vector{Float64}, nzval))
end

function klu!(K::KLUFactorization{U}, S::SparseMatrixCSC{U}) where {U}
    size(K) == size(S) || throw(ArgumentError("Sizes of K and S must match."))
    return klu!(K, S.nzval)
end
#B is the modified argument here. To match with the math it should be (klu, B). But convention is
# modified first. Thoughts?
for Tv ∈ KLUValueTypes, Ti ∈ KLUIndexTypes
    solve = _klu_name("solve", Tv, Ti)
    @eval begin
        function solve!(klu::KLUFactorization{$Tv, $Ti}, B::StridedVecOrMat{$Tv})
            stride(B, 1) == 1 || throw(ArgumentError("B must have unit strides"))
            klu._numeric == C_NULL && klu_factor!(klu)
            size(B, 1) == size(klu, 1) || throw(DimensionMismatch())
            isok = $solve(klu._symbolic, klu._numeric, size(B, 1), size(B, 2), B, Ref(klu.common))
            isok == 0 && kluerror(klu.common)
            return B
        end
    end
end

for Tv ∈ KLUValueTypes, Ti ∈ KLUIndexTypes
    tsolve = _klu_name("tsolve", Tv, Ti)
    if Tv === :ComplexF64
        call = :($tsolve(klu._symbolic, klu._numeric, size(B, 1), size(B, 2), B, conj, Ref(klu.common)))
    else
        call = :($tsolve(klu._symbolic, klu._numeric, size(B, 1), size(B, 2), B, Ref(klu.common)))
    end
    @eval begin
        function solve!(klu::Adjoint{$Tv, KLUFactorization{$Tv, $Ti}}, B::StridedVecOrMat{$Tv})
            conj = 1
            klu = parent(klu)
            stride(B, 1) == 1 || throw(ArgumentError("B must have unit strides"))
            klu._numeric == C_NULL && klu_factor!(klu)
            size(B, 1) == size(klu, 1) || throw(DimensionMismatch())
            isok = $call
            isok == 0 && kluerror(klu.common)
            return B
        end
        function solve!(klu::Transpose{$Tv, KLUFactorization{$Tv, $Ti}}, B::StridedVecOrMat{$Tv})
            conj = 0
            klu = parent(klu)
            stride(B, 1) == 1 || throw(ArgumentError("B must have unit strides"))
            klu._numeric == C_NULL && klu_factor!(klu)
            size(B, 1) == size(klu, 1) || throw(DimensionMismatch())
            isok = $call
            isok == 0 && kluerror(klu.common)
            return B
        end
    end
end

function solve(klu, B)
    X = copy(B)
    return solve!(klu, X)
end
ldiv!(klu::KLUFactorization{Tv}, B::StridedVecOrMat{Tv}) where {Tv<:KLUTypes} =
    solve!(klu, B)
ldiv!(klu::LinearAlgebra.AdjOrTrans{Tv, KLUFactorization{Tv, Ti}}, B::StridedVecOrMat{Tv}) where {Tv, Ti} =
    solve!(klu, B)
function ldiv!(klu::KLUFactorization{<:AbstractFloat}, B::StridedVecOrMat{<:Complex})
    imagX = solve(klu, imag(B))
    realX = solve(klu, real(B))
    map!(complex, B, realX, imagX)
end

function ldiv!(klu::LinearAlgebra.AdjOrTrans{Tv, KLUFactorization{Tv, Ti}}, B::StridedVecOrMat{<:Complex}) where {Tv<:AbstractFloat, Ti}
    imagX = solve(klu, imag(B))
    realX = solve(klu, real(B))
    map!(complex, B, realX, imagX)
end

end
